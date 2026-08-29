import SwiftUI

struct PortfolioGridView: View {
    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var subscription: SubscriptionStore
    @EnvironmentObject private var admin: AdminSessionStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var searchText = ""
    @State private var showSubscription = false

    private var columns: [GridItem] {
        if horizontalSizeClass == .regular {
            return Array(repeating: GridItem(.flexible(), spacing: 14), count: 3)
        }
        return [GridItem(.adaptive(minimum: 155, maximum: 320), spacing: 12)]
    }

    private var filteredPortfolios: [Portfolio] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.portfolios }
        return store.portfolios.filter { portfolio in
            [portfolio.title, portfolio.subtitle, portfolio.eyebrow]
                .contains { $0.localizedCaseInsensitiveContains(query) }
                || portfolio.images.contains { $0.altText.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("PORTFOLIO")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(3)
                            .foregroundStyle(AppTheme.gold)
                        Text("作品")
                            .font(.editorial(42))
                        Text("每一组影像，都是一次人物叙事。")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.muted)

                        HStack(spacing: 7) {
                            Image(systemName: store.contentOrigin == .network ? "checkmark.icloud" : "internaldrive")
                            Text(store.syncStatus)
                            if let lastUpdated = store.lastUpdated {
                                Text("· \(lastUpdated.formatted(date: .omitted, time: .shortened))")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(AppTheme.gold)

                        Button { showSubscription = true } label: {
                            HStack(spacing: 10) {
                                Image(systemName: hasFullAccess ? "checkmark.seal.fill" : "lock.open.fill")
                                    .foregroundStyle(AppTheme.gold)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hasFullAccess ? "全部作品已解锁" : "订阅解锁全部照片")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AppTheme.warmWhite)
                                    Text(hasFullAccess ? "可浏览所有相册内容" : "每个相册免费预览 3 张 · \(subscription.localizedMonthlyPrice)/月")
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.muted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.muted)
                            }
                            .padding(14)
                            .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(filteredPortfolios) { portfolio in
                            NavigationLink(value: portfolio) {
                                PortfolioGridCard(portfolio: portfolio)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)

                    if filteredPortfolios.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .foregroundStyle(AppTheme.warmWhite)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 50)
                    }

                    if let status = store.statusMessage {
                        Label(status, systemImage: "wifi.slash")
                            .font(.caption)
                            .foregroundStyle(AppTheme.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.bottom, 36)
            }
            .contentMargins(.bottom, 84, for: .scrollContent)
            .refreshable { await refreshContent() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Portfolio.self) { portfolio in
            PortfolioDetailView(portfolio: portfolio)
        }
        .searchable(text: $searchText, prompt: "搜索主题、风格或描述")
        .toolbarBackground(AppTheme.ink, for: .navigationBar)
        .sheet(isPresented: $showSubscription) {
            SubscriptionPaywallView()
        }
    }

    private var hasFullAccess: Bool {
        subscription.hasFullPhotoAccess || admin.isAuthenticated
    }

    private func refreshContent() async {
        await store.refresh()
        if admin.isAuthenticated {
            if let manifest = try? await admin.fetchContent() {
                store.applyPublishedManifest(manifest)
            }
        } else if let entitlementJWS = subscription.entitlementJWS {
            await store.refreshPremiumContent(with: entitlementJWS)
        }
    }
}

private struct PortfolioGridCard: View {
    let portfolio: Portfolio
    @EnvironmentObject private var subscription: SubscriptionStore
    @EnvironmentObject private var admin: AdminSessionStore

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ArtworkImage(url: portfolio.coverURL)
                .aspectRatio(3 / 4, contentMode: .fit)
                .frame(maxWidth: .infinity)
            LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 5) {
                Text(portfolio.eyebrow)
                    .font(.system(size: 7, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(AppTheme.gold)
                Text(portfolio.title)
                    .font(.editorial(22))
            }
            .foregroundStyle(.white)
            .padding(14)

            if !subscription.hasFullPhotoAccess, !admin.isAuthenticated,
               portfolio.displayImageCount > PhotoAccessPolicy.freePreviewCount {
                VStack {
                    HStack {
                        Spacer()
                        Label("3 张预览", systemImage: "lock.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.88))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .background(.black.opacity(0.58), in: Capsule())
                    }
                    Spacer()
                }
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

struct PortfolioDetailView: View {
    let portfolio: Portfolio
    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var recentlyViewed: RecentlyViewedStore
    @EnvironmentObject private var subscription: SubscriptionStore
    @EnvironmentObject private var admin: AdminSessionStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedImage: PortfolioImage?
    @State private var showSubscription = false

    private var columns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
    }

    private var heroHeight: CGFloat {
        horizontalSizeClass == .regular ? 660 : 500
    }

    private var galleryImages: [PortfolioImage] {
        Array(currentPortfolio.images.dropFirst())
    }

    private var lockedImageNumbers: [Int] {
        guard !hasFullAccess,
              currentPortfolio.displayImageCount > currentPortfolio.images.count else { return [] }
        return Array((currentPortfolio.images.count + 1)...currentPortfolio.displayImageCount)
    }

    private var hasFullAccess: Bool {
        subscription.hasFullPhotoAccess || admin.isAuthenticated
    }

    private var currentPortfolio: Portfolio {
        store.portfolios.first { $0.id == portfolio.id } ?? portfolio
    }

    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let firstImage = currentPortfolio.images.first {
                        Button { selectedImage = firstImage } label: {
                            PortfolioHeroArtwork(
                                image: firstImage,
                                portfolio: currentPortfolio
                            )
                            .frame(maxWidth: 760)
                            .frame(height: heroHeight)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("打开\(firstImage.altText)")
                    } else {
                        PortfolioEmptyArtwork(portfolio: currentPortfolio)
                            .frame(height: 360)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(currentPortfolio.displayImageCount) 帧影像")
                                .foregroundStyle(AppTheme.warmWhite)
                            Text(hasFullAccess ? "点击照片全屏浏览" : "前 3 张可免费预览")
                                .font(.caption2)
                        }
                        Spacer()
                        if hasFullAccess {
                            Label("已解锁", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(AppTheme.gold)
                        } else {
                            Button { showSubscription = true } label: {
                                Label("\(subscription.localizedMonthlyPrice)/月解锁", systemImage: "lock.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppTheme.gold)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)

                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(Array(galleryImages.enumerated()), id: \.element.id) { offset, image in
                            let imageNumber = offset + 2
                            let canAccess = PhotoAccessPolicy.canAccess(
                                image,
                                in: currentPortfolio,
                                hasSubscription: subscription.hasFullPhotoAccess,
                                isAdministrator: admin.isAuthenticated
                            )
                            Button {
                                if canAccess {
                                    selectedImage = image
                                } else {
                                    showSubscription = true
                                }
                            } label: {
                                if canAccess {
                                    PortfolioGalleryTile(image: image, number: imageNumber)
                                } else {
                                    LockedPortfolioGalleryTile(number: imageNumber)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(canAccess ? image.altText : "第 \(imageNumber) 张照片，需要订阅")
                        }

                        ForEach(lockedImageNumbers, id: \.self) { imageNumber in
                            Button { showSubscription = true } label: {
                                LockedPortfolioGalleryTile(number: imageNumber)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("第 \(imageNumber) 张照片，需要订阅")
                        }
                    }
                    .padding(.horizontal, 12)

                    if currentPortfolio.displayImageCount == 1 {
                        Text("本组影像暂时只有封面作品")
                            .font(.caption)
                            .foregroundStyle(AppTheme.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    }

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "c.circle")
                            .foregroundStyle(AppTheme.gold)
                        Text("本组照片已获合法展示授权并受版权保护，仅限在本 App 内浏览；未经许可不得下载、复制、转载、改编或用于商业用途。")
                            .font(.caption)
                            .lineSpacing(4)
                            .foregroundStyle(AppTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 4))
                    .padding(.horizontal, 12)
                    .padding(.top, 24)
                }
                .padding(.bottom, 30)
            }
        }
        .navigationTitle(currentPortfolio.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .onAppear { recentlyViewed.record(currentPortfolio) }
        .fullScreenCover(item: $selectedImage) { image in
            GalleryViewer(portfolio: currentPortfolio, initialImage: image)
        }
        .sheet(isPresented: $showSubscription) {
            SubscriptionPaywallView()
        }
    }
}

private struct PortfolioHeroArtwork: View {
    let image: PortfolioImage
    let portfolio: Portfolio

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            EditorialArtworkImage(url: image.url)

            LinearGradient(
                colors: [.clear, AppTheme.ink.opacity(0.18), AppTheme.ink.opacity(0.96)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 10) {
                Text(portfolio.eyebrow)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(AppTheme.gold)
                Text(portfolio.title)
                    .font(.editorial(46))
                Text(portfolio.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 22)
            .padding(.bottom, 24)
        }
        .contentShape(Rectangle())
    }
}

private struct PortfolioGalleryTile: View {
    let image: PortfolioImage
    let number: Int

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            EditorialArtworkImage(url: image.url)

            Text(String(format: "%02d", number))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.84))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.black.opacity(0.52), in: Capsule())
                .padding(8)
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(.white.opacity(0.07), lineWidth: 0.5)
        }
    }
}

private struct LockedPortfolioGalleryTile: View {
    let number: Int

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.elevatedInk, AppTheme.ink, AppTheme.gold.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(AppTheme.gold)
                Text("订阅后查看")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.warmWhite)
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text(String(format: "%02d", number))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.58))
                        .padding(8)
                }
            }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(AppTheme.gold.opacity(0.18), lineWidth: 0.5)
        }
    }
}

private struct EditorialArtworkImage: View {
    let url: URL

    var body: some View {
        GeometryReader { proxy in
            AsyncImage(
                url: url,
                transaction: Transaction(animation: .easeOut(duration: 0.3))
            ) { phase in
                switch phase {
                case .empty:
                    placeholder
                        .overlay { ProgressView().tint(AppTheme.gold) }
                case .success(let image):
                    ZStack {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .blur(radius: 22)
                            .scaleEffect(1.12)
                            .opacity(0.3)

                        Color.black.opacity(0.22)

                        image
                            .resizable()
                            .scaledToFit()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                    .transition(.opacity)
                case .failure:
                    placeholder
                        .overlay {
                            Image(systemName: "photo")
                                .font(.title2)
                                .foregroundStyle(AppTheme.muted)
                        }
                @unknown default:
                    placeholder
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(AppTheme.elevatedInk)
        .clipped()
    }

    private var placeholder: some View {
        ZStack {
            AppTheme.elevatedInk
            LinearGradient(
                colors: [.white.opacity(0.035), .clear, AppTheme.gold.opacity(0.045)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private struct PortfolioEmptyArtwork: View {
    let portfolio: Portfolio

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.largeTitle)
                .foregroundStyle(AppTheme.gold)
            Text(portfolio.title)
                .font(.editorial(34))
            Text("暂无可浏览照片")
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.elevatedInk)
    }
}

struct GalleryViewer: View {
    let portfolio: Portfolio
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var subscription: SubscriptionStore
    @EnvironmentObject private var admin: AdminSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int

    init(portfolio: Portfolio, initialImage: PortfolioImage) {
        self.portfolio = portfolio
        _selection = State(initialValue: initialImage.id)
    }

    private var selected: PortfolioImage? {
        accessibleImages.first { $0.id == selection }
    }

    private var selectedIndex: Int {
        (accessibleImages.firstIndex { $0.id == selection } ?? 0) + 1
    }

    private var accessibleImages: [PortfolioImage] {
        PhotoAccessPolicy.accessibleImages(
            in: portfolio,
            hasSubscription: subscription.hasFullPhotoAccess,
            isAdministrator: admin.isAuthenticated
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(accessibleImages) { image in
                    ZoomableArtwork(image: image)
                        .tag(image.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    Text("\(selectedIndex) / \(accessibleImages.count)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Button {
                        if let selected { favorites.toggle(selected) }
                    } label: {
                        Image(systemName: selected.map(favorites.contains) == true ? "heart.fill" : "heart")
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .tint(selected.map(favorites.contains) == true ? AppTheme.gold : .white)
                    .accessibilityLabel(selected.map(favorites.contains) == true ? "取消收藏" : "收藏照片")
                }
                Spacer()
                VStack(spacing: 6) {
                    Text(portfolio.title)
                        .font(.editorial(23))
                    Text("双指缩放 · 左右翻页")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .foregroundStyle(.white)
            .padding(18)
        }
        .statusBarHidden()
        .protectedFromScreenCapture()
        .onChange(of: accessibleImages.map(\.id)) { _, imageIDs in
            if !imageIDs.contains(selection), let firstID = imageIDs.first {
                selection = firstID
            }
        }
    }
}

private struct ZoomableArtwork: View {
    let image: PortfolioImage
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ArtworkImage(url: image.fullSizeURL, contentMode: .fit)
            .scaleEffect(scale)
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        scale = min(max(lastScale * value.magnification, 1), 4)
                    }
                    .onEnded { _ in
                        lastScale = scale
                        if scale < 1.05 {
                            withAnimation(.spring) {
                                scale = 1
                                lastScale = 1
                            }
                        }
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.32)) {
                    scale = scale > 1 ? 1 : 2
                    lastScale = scale
                }
            }
    }
}
