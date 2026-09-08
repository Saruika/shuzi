import SwiftUI

private enum AboutContactIcon {
    case system(String)
    case brandAsset(String)
}

struct AboutView: View {
    @Environment(\.openURL) private var openExternalURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var hongguoTask: Task<Void, Never>?
    @State private var isCheckingHongguo = false
    @State private var hongguoMessage = ""
    @State private var showsHongguoMessage = false
    @EnvironmentObject private var admin: AdminSessionStore
    @Environment(LocalWeatherStore.self) private var localWeather
    @EnvironmentObject private var portfolioStore: PortfolioStore
    @EnvironmentObject private var fanAccount: FanAccountStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var presentsAdminAccess = false
    // The managed About portrait is published as a 2:3 editorial image. Keep
    // the visual canvas on the same ratio so a fitted image and its caption
    // share one boundary instead of placing the caption in letterbox space.
    private let portraitAspectRatio: CGFloat = 2 / 3
    private let portraitCaptionInset: CGFloat = 22
    private let singleColumnCaptionSafetyMargin: CGFloat = 12

    var body: some View {
        GeometryReader { scene in
            ZStack {
                AppTheme.ink.ignoresSafeArea()
                if UIDevice.current.userInterfaceIdiom == .pad,
                   usesTwoColumnLayout(in: scene) {
                    pinnedPortraitLayout(in: scene)
                        .overlay(alignment: .bottom) { visibleBottomTestProbe }
                } else {
                    scrollingLayout(in: scene)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onDisappear { hongguoTask?.cancel(); isCheckingHongguo = false }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { hongguoTask?.cancel(); isCheckingHongguo = false }
        }
        .alert("观看链接提示", isPresented: $showsHongguoMessage) {
            Button("知道了", role: .cancel) { }
        } message: { Text(hongguoMessage) }
        .fullScreenCover(isPresented: $presentsAdminAccess) {
            SecureCaptureSurface(
                owner: .fullScreenPresentation,
                onExit: { presentsAdminAccess = false }
            ) {
                AdminAccessView(onClose: { presentsAdminAccess = false })
                    .environmentObject(admin)
                    .environmentObject(portfolioStore)
            }
        }
    }

    private func pinnedPortraitLayout(in scene: GeometryProxy) -> some View {
        let contentWidth = min(max(0, scene.size.width - 48), 1_164)
        let columnWidth = max(0, (contentWidth - 24) / 2)
        let portraitWidth = min(columnWidth, twoColumnPortraitHeight(in: scene) * portraitAspectRatio)

        return HStack(alignment: .top, spacing: 24) {
            // The portrait and its caption live outside every scroll view.
            // Fit one shared 2:3 canvas to the current window, including after
            // rotation or resizing; do not stretch or crop the photograph.
            portrait(captionBottomPadding: portraitCaptionInset)
                .frame(width: portraitWidth, height: portraitWidth / portraitAspectRatio)
                .frame(width: columnWidth, alignment: .top)

            ScrollView {
                profileDetails
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
            }
            .scrollIndicators(.hidden)
            .floatingTabBarScrollClearance()
            .accessibilityIdentifier("about-details-scroll")
            .frame(width: columnWidth, height: max(0, scene.size.height))
        }
        .frame(width: contentWidth, height: max(0, scene.size.height), alignment: .top)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func scrollingLayout(in scene: GeometryProxy) -> some View {
        ScrollView {
            Group {
                if usesTwoColumnLayout(in: scene) {
                    HStack(alignment: .top, spacing: 24) {
                        portrait(captionBottomPadding: portraitCaptionInset)
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: twoColumnPortraitHeight(in: scene),
                                alignment: .top
                            )
                        profileDetails
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    }
                    .frame(maxWidth: 1_164)
                    .padding(.horizontal, 24)
                } else {
                    VStack(spacing: 0) {
                        portrait(
                            captionBottomPadding: singleColumnCaptionBottomPadding(in: scene)
                        )
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
        .overlay(alignment: .bottom) {
            visibleBottomTestProbe
        }
        .floatingTabBarScrollClearance()
    }

    private func usesTwoColumnLayout(in scene: GeometryProxy) -> Bool {
        !dynamicTypeSize.isAccessibilitySize
            && dynamicTypeSize < .xxxLarge
            && (horizontalSizeClass == .regular || verticalSizeClass == .compact)
            && (UIDevice.current.userInterfaceIdiom != .pad || scene.size.width >= 700)
    }

    private func twoColumnPortraitHeight(in scene: GeometryProxy) -> CGFloat {
        max(
            0,
            scene.size.height
                - scene.safeAreaInsets.top
                - scene.safeAreaInsets.bottom
        )
    }

    private func singleColumnCaptionBottomPadding(in scene: GeometryProxy) -> CGFloat {
        let minimumPadding = portraitCaptionInset + singleColumnCaptionSafetyMargin
        let portraitWidth = min(max(scene.size.width, 0), 720)
        let portraitHeight = portraitWidth / portraitAspectRatio
        let visibleHeight = max(
            0,
            scene.size.height
                - scene.safeAreaInsets.top
                - scene.safeAreaInsets.bottom
        )
        let overflow = max(0, portraitHeight - visibleHeight)
        return minimumPadding + overflow
    }

    @ViewBuilder
    private var visibleBottomTestProbe: some View {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains(
            "-expose-about-visible-bottom-for-visual-testing"
        ) {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("关于页可见区域下边界")
                .accessibilityIdentifier("about-visible-bottom")
                .allowsHitTesting(false)
        }
#endif
    }

    private var profileDetails: some View {
        VStack(spacing: 0) {
            biography
            profileActions
            links
            fanAccountAccess
            settingsAccess
            copyrightNotice
            privacyAccess
            adminAccess
            weatherAttribution
        }
    }

    private func portrait(captionBottomPadding: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let portraitURL = portfolioStore.aboutPortraitURL {
                ArtworkImage(url: portraitURL, contentMode: .fit)
                    .accessibilityLabel("易姝形象照")
                    .accessibilityIdentifier("about-portrait")
            } else {
                ZStack {
                    AppTheme.elevatedInk
                    Image(systemName: "person.crop.rectangle")
                        .font(.largeTitle.weight(.light))
                        .foregroundStyle(AppTheme.gold)
                }
                    .accessibilityLabel("易姝形象照")
                    .accessibilityValue("正在安全加载")
                    .accessibilityIdentifier("about-portrait")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("YI SHU")
                    .font(.caption2.weight(.semibold))
                    .tracking(4)
                    .foregroundStyle(AppTheme.gold)
                    // Decorative transliteration; the following Chinese name
                    // carries the same semantic content for VoiceOver.
                    .accessibilityHidden(true)
                Text("易姝")
                    .font(.system(.largeTitle, design: .serif))
                Text("短剧演员 / 模特 / 视频创作者")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.warmWhite)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("about-role-summary")
            }
            .foregroundStyle(AppTheme.warmWhite)
            .padding(.horizontal, portraitCaptionInset)
            .padding(.top, portraitCaptionInset)
            .padding(.bottom, captionBottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { EditorialCaptionBackdrop().padding(.top, -24) }
        }
        .aspectRatio(portraitAspectRatio, contentMode: .fit)
        .background {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-expose-about-portrait-canvas-for-testing") {
                // Measure the actual canvas, not the retry button to which
                // SwiftUI can forward an image's accessibility identifier.
                Color.clear
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("人物图片画布")
                    .accessibilityIdentifier("about-portrait-canvas")
                    .allowsHitTesting(false)
            }
#endif
        }
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
                .foregroundStyle(AppTheme.muted)
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
                    Divider().overlay(AppTheme.line)
                    stat("浙江 · 杭州", "所在地")
                    Divider().overlay(AppTheme.line)
                    stat("合作中", "状态")
                }
            } else {
                HStack(spacing: 0) {
                    stat("演员", "身份")
                    Divider().overlay(AppTheme.line)
                    stat("浙江 · 杭州", "所在地")
                    Divider().overlay(AppTheme.line)
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
            contactLink(
                "工作联系",
                detail: "369476120@qq.com",
                icon: .system("envelope"),
                url: ContentCatalog.emailURL
            )
            contactLink(
                "小红书",
                detail: "一只梳子君",
                icon: .brandAsset("XiaohongshuBrandIcon"),
                url: ContentCatalog.xiaohongshuURL
            )
            .accessibilityIdentifier("about-xiaohongshu-link")
            contactLink(
                "抖音",
                detail: "一只梳子君",
                icon: .brandAsset("DouyinBrandIcon"),
                url: ContentCatalog.douyinURL
            )
            .accessibilityIdentifier("about-douyin-link")
            contactLink(
                "红果短剧",
                detail: "易姝",
                icon: .brandAsset("HongguoBrandIcon"),
                url: DramaLinkPolicy.profileCandidate(in: portfolioStore.dramas)
            )
            .environment(\.openURL, OpenURLAction { url in
                checkAndOpenHongguo(url)
                return .handled
            })
            .disabled(isCheckingHongguo)
            .overlay(alignment: .trailing) {
                if isCheckingHongguo { ProgressView().padding(.trailing, 16) }
            }
            .accessibilityIdentifier("about-hongguo-link")
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
                .foregroundStyle(AppTheme.muted)
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

    private func checkAndOpenHongguo(_ url: URL) {
        guard !isCheckingHongguo else { return }
        isCheckingHongguo = true
        hongguoTask = Task { @MainActor in
            let health = await DramaLinkChecker.check(url, requireActor: true)
            guard !Task.isCancelled else { return }
            isCheckingHongguo = false
            guard scenePhase == .active, url == DramaLinkPolicy.profileCandidate(in: portfolioStore.dramas) else { return }
            guard health == .available else {
                hongguoMessage = health.message; showsHongguoMessage = true; return
            }
            openExternalURL(url) { accepted in
                if !accepted { hongguoMessage = "暂时无法打开红果页面，请稍后再试。"; showsHongguoMessage = true }
            }
        }
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
                    .background(AppTheme.subtleFill, in: Circle())
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
                    .foregroundStyle(AppTheme.muted)
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

    private var settingsAccess: some View {
        NavigationLink {
            UserSettingsView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(AppTheme.gold)
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text("设置").font(.subheadline.weight(.semibold))
                    Text("\(AppearanceStore.shared.theme.name) · 账号与通知 · 隐私")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.muted)
            }
            .foregroundStyle(AppTheme.warmWhite)
            .padding(15)
            .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("about-settings")
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
                    .background(AppTheme.subtleFill, in: Circle())
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
                    .foregroundStyle(AppTheme.muted)
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    AsyncImage(url: AppearanceStore.shared.theme.colorScheme == .light
                               ? localWeather.attributionLightMarkURL : localWeather.attributionMarkURL) { phase in
                        if case .success(let image) = phase {
                            image
                                .resizable()
                                .scaledToFit()
                                .frame(width: 108, height: 28, alignment: .leading)
                        } else {
                            Text(localWeather.weatherProviderName)
                                .font(.caption.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                }

                Text("天气数据由 Apple Weather 提供")
                    .font(.footnote.weight(.medium))
                Text("查看数据来源、版权与许可信息")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
            }
            .foregroundStyle(AppTheme.warmWhite)
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Apple Weather 天气数据来源与许可")
        .accessibilityAddTraits(.isLink)
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

    private func contactLink(
        _ title: String,
        detail: String,
        icon: AboutContactIcon,
        url: URL
    ) -> some View {
        Link(destination: url) {
            HStack(spacing: 14) {
                contactIcon(icon)
                    .frame(width: 36, height: 36)
                    .background(AppTheme.subtleFill, in: Circle())
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
                    .foregroundStyle(AppTheme.muted)
            }
            .foregroundStyle(AppTheme.warmWhite)
            .padding(15)
            .frame(minHeight: 48)
            .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func contactIcon(_ icon: AboutContactIcon) -> some View {
        switch icon {
        case let .system(name):
            Image(systemName: name)
                .font(.body)
                .foregroundStyle(AppTheme.gold)
        case let .brandAsset(name):
            Image(name)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}
