import SwiftUI

struct PortfolioGridView: View {
    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var admin: AdminSessionStore
    @EnvironmentObject private var fanAccount: FanAccountStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var searchText = ""

    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }
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
                            .font(.caption2.weight(.semibold))
                            .tracking(3)
                            .foregroundStyle(AppTheme.gold)
                        Text("作品")
                            .font(.system(.largeTitle, design: .serif))
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("portfolio-heading")
                        Text("每一组影像，都是一次人物叙事。")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.muted)

                        HStack(spacing: 7) {
                            Image(systemName: store.contentOrigin == .network ? "checkmark.icloud" : "internaldrive")
                            if let lastUpdated = store.lastUpdated {
                                Text("\(store.syncStatus) \(lastUpdated.formatted(date: .omitted, time: .shortened))")
                            } else {
                                Text(store.syncStatus)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(AppTheme.gold)

                        HStack(spacing: 10) {
                            Image(systemName: "photo.stack.fill")
                                .foregroundStyle(AppTheme.gold)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("全部作品开放浏览")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AppTheme.warmWhite)
                                    .accessibilityAddTraits(.isHeader)
                                Text("相册持续更新 · 影像内容受版权保护")
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.muted)
                            }
                            Spacer()
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.gold)
                        }
                        .padding(14)
                        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(filteredPortfolios) { portfolio in
                            NavigationLink(value: portfolio) {
                                PortfolioGridCard(portfolio: portfolio)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("portfolio-card-\(portfolio.id)")
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
            .floatingTabBarScrollClearance()
            .refreshable { await refreshContent() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Portfolio.self) { portfolio in
            PortfolioDetailView(portfolio: portfolio)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            PortfolioSearchBar(text: $searchText)
                .padding(.horizontal, 20)
                .padding(.top, horizontalSizeClass == .regular ? -1 : 0)
                .padding(.bottom, 10)
                .background(AppTheme.ink)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func refreshContent() async {
        // AdminView exclusively owns administrator full-manifest requests.
        // This surface only refreshes the currently approved fan scope.
        guard !admin.isAuthenticated, fanAccount.isApproved else { return }
        let refreshID = store.beginContentRefresh()
        do {
            let manifest = try await fanAccount.fetchApprovedContent()
            guard !admin.isAuthenticated, fanAccount.isApproved else {
                store.cancelContentRefresh(refreshID)
                return
            }
            store.completeContentRefresh(refreshID, with: manifest)
            store.enforcePermissionScope(
                canViewFullGallery: fanAccount.hasPermission(.galleryFull),
                canViewVideo: fanAccount.hasPermission(.videoView)
            )
        } catch {
            guard !admin.isAuthenticated, fanAccount.isApproved else {
                store.cancelContentRefresh(refreshID)
                return
            }
            store.failContentRefresh(refreshID)
        }
    }
}

private struct PortfolioSearchBar: View {
    @Binding var text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.medium))
                    .foregroundStyle(AppTheme.muted)
                    .accessibilityHidden(true)

                TextField(
                    "",
                    text: $text,
                    prompt: Text("搜索作品")
                        .foregroundStyle(AppTheme.muted)
                )
                    .font(.body)
                    .layoutPriority(1)
                    .focused($isFocused)
                    .submitLabel(.search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("搜索作品")
                    .accessibilityIdentifier("portfolio-search-field")

                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AppTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 15)
            .frame(minHeight: horizontalSizeClass == .regular ? 44 : 48)
            .background(AppTheme.elevatedInk, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.1), lineWidth: 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("portfolio-search-control")

            if isFocused {
                Button("取消") {
                    text = ""
                    isFocused = false
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.gold)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .trailing))
                )
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isFocused)
    }
}

private struct PortfolioGridCard: View {
    let portfolio: Portfolio

    private var editorialEyebrow: String {
        portfolio.eyebrow.replacingOccurrences(of: " · ", with: "\n")
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ArtworkImage(url: portfolio.coverURL)
                .aspectRatio(3 / 4, contentMode: .fit)
                .frame(maxWidth: .infinity)
            LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 5) {
                Text(editorialEyebrow)
                    .font(.caption2.weight(.semibold))
                    .tracking(0.7)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .foregroundStyle(AppTheme.gold)
                    .accessibilityLabel(portfolio.eyebrow)
                Text(portfolio.title)
                    .font(.system(.title3, design: .serif))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.white)
            }
            .padding(14)

        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

struct PortfolioDetailView: View {
    let portfolio: Portfolio
    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var recentlyViewed: RecentlyViewedStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedImage: PortfolioImage?

    private var columns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize
            ? 1
            : (horizontalSizeClass == .regular ? 3 : 2)
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
    }

    private var heroHeight: CGFloat {
        if dynamicTypeSize.isAccessibilitySize {
            return horizontalSizeClass == .regular ? 720 : 600
        }
        return horizontalSizeClass == .regular ? 660 : 500
    }

    private var galleryImages: [PortfolioImage] {
        Array(currentPortfolio.images.dropFirst())
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
                        .accessibilityIdentifier("portfolio-open-image-\(firstImage.id)")
                        .accessibilityLabel("打开\(firstImage.altText)")
                    } else {
                        PortfolioEmptyArtwork(portfolio: currentPortfolio)
                            .frame(height: 360)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(currentPortfolio.displayImageCount) 帧影像")
                                .foregroundStyle(AppTheme.warmWhite)
                                .accessibilityAddTraits(.isHeader)
                            Text(accessDescription)
                                .font(.caption2)
                        }
                        Spacer()
                        Label("完整展示", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(AppTheme.gold)
                    }
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)

                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(Array(galleryImages.enumerated()), id: \.element.id) { offset, image in
                            let imageNumber = offset + 2
                            Button { selectedImage = image } label: {
                                PortfolioGalleryTile(image: image, number: imageNumber)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(image.altText)
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
        .accessibilityIdentifier("portfolio-detail-\(currentPortfolio.id)")
        .navigationTitle(currentPortfolio.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            recentlyViewed.record(currentPortfolio)
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-open-gallery-for-visual-testing") {
                selectedImage = currentPortfolio.images.first
            }
#endif
        }
        .fullScreenCover(item: $selectedImage) { image in
            SecureCaptureSurface(
                owner: .fullScreenPresentation,
                onExit: { selectedImage = nil }
            ) {
                GalleryViewer(
                    portfolio: currentPortfolio,
                    initialImage: image,
                    onClose: { selectedImage = nil }
                )
                    .environmentObject(store)
                    .environmentObject(favorites)
            }
        }
    }

    private var accessDescription: String {
        "点击照片全屏浏览"
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
                    .font(.caption2.weight(.semibold))
                    .tracking(2)
                    .foregroundStyle(AppTheme.gold)
                Text(portfolio.title)
                    .font(.system(.largeTitle, design: .serif))
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
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
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

private struct EditorialArtworkImage: View {
    let url: URL

    var body: some View {
        ZStack {
            placeholder
            Color.black.opacity(0.12)
            ArtworkImage(url: url, contentMode: .fit)
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
                .font(.system(.title, design: .serif))
                .accessibilityAddTraits(.isHeader)
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
    let onClose: () -> Void
    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var favorites: FavoritesStore
    @Environment(\.displayScale) private var displayScale
    @State private var selection: Int

    init(
        portfolio: Portfolio,
        initialImage: PortfolioImage,
        onClose: @escaping () -> Void
    ) {
        self.portfolio = portfolio
        self.onClose = onClose
        _selection = State(initialValue: initialImage.id)
    }

    private var selected: PortfolioImage? {
        accessibleImages.first { $0.id == selection }
    }

    private var selectedIndex: Int {
        (accessibleImages.firstIndex { $0.id == selection } ?? 0) + 1
    }

    private var accessibleImages: [PortfolioImage] {
        store.portfolios.first(where: { $0.id == portfolio.id })?.images ?? portfolio.images
    }

    var body: some View {
        GeometryReader { viewport in
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    galleryToolbar
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    TabView(selection: $selection) {
                        ForEach(accessibleImages) { image in
                            ZoomableArtwork(image: image)
                                .tag(image.id)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .padding(.horizontal, galleryHorizontalInset(in: viewport.size))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)

                    galleryCaption
                        .padding(.horizontal, 18)
                        .padding(.top, 8)
                        .padding(.bottom, 16)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .task(id: prefetchRequestID(for: viewport.size)) {
                await ArtworkImagePrefetcher.prefetch(
                    urls: prefetchURLs,
                    maxPixelSize: min(
                        2_200,
                        max(
                            320,
                            Int(ceil(max(viewport.size.width, viewport.size.height) * displayScale))
                        )
                    )
                )
            }
        }
        .statusBarHidden()
        .protectedFromScreenCapture()
        .onChange(of: accessibleImages.map(\.id)) { _, imageIDs in
            if !imageIDs.contains(selection), let firstID = imageIDs.first {
                selection = firstID
            }
        }
    }

    private var galleryToolbar: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("关闭图片")
            .accessibilityIdentifier("gallery-close")

            Spacer()

            Text("\(selectedIndex) / \(accessibleImages.count)")
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(.white.opacity(0.7))
                .accessibilityLabel("第 \(selectedIndex) 张，共 \(accessibleImages.count) 张")
                .accessibilityIdentifier("gallery-counter")

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
    }

    private var galleryCaption: some View {
        VStack(spacing: 6) {
            Text(portfolio.title)
                .font(.system(.title3, design: .serif))
                .accessibilityAddTraits(.isHeader)
            Text("双指缩放 · 左右翻页")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
        }
        .accessibilityIdentifier("gallery-caption")
    }

    private func galleryHorizontalInset(in size: CGSize) -> CGFloat {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return 0 }
        return size.width > size.height ? 36 : 24
    }

    private var prefetchURLs: [URL] {
        guard let index = accessibleImages.firstIndex(where: { $0.id == selection }) else {
            return []
        }
        let lowerBound = max(accessibleImages.startIndex, index - 1)
        let upperBound = min(accessibleImages.index(before: accessibleImages.endIndex), index + 1)
        return accessibleImages[lowerBound...upperBound].flatMap { image in
            [image.url, image.fullSizeURL]
        }
    }

    private func prefetchRequestID(for size: CGSize) -> String {
        "\(selection)#\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }
}

private struct ProgressiveGalleryArtwork: View {
    let image: PortfolioImage
    let targetSize: CGSize

    var body: some View {
        ZStack {
            ArtworkImage(url: image.url, contentMode: .fit)

            if image.fullSizeURL != image.url {
                DownsampledAsyncImage(
                    url: image.fullSizeURL,
                    targetSize: targetSize
                ) { phase in
                    switch phase {
                    case .success(let fullResolutionImage):
                        fullResolutionImage
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: targetSize.width, height: targetSize.height)
                            .transition(.opacity)
                    case .empty, .failure:
                        Color.clear
                    @unknown default:
                        Color.clear
                    }
                }
            }
        }
        .frame(width: targetSize.width, height: targetSize.height)
        .clipped()
    }
}

private struct ZoomableArtwork: View {
    let image: PortfolioImage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            ProgressiveGalleryArtwork(image: image, targetSize: proxy.size)
                .scaleEffect(scale)
                .offset(offset)
                .simultaneousGesture(magnifyGesture(in: proxy.size))
                .gesture(
                    dragGesture(in: proxy.size),
                    including: scale > 1.01 ? .all : .none
                )
                .onTapGesture(count: 2) {
                    updateTransform {
                        if scale > 1.01 {
                            resetTransform()
                        } else {
                            scale = 2
                            lastScale = 2
                            offset = .zero
                            lastOffset = .zero
                        }
                    }
                }
                // Keep the image loader's retry control reachable if loading
                // fails while exposing zoom actions on the containing photo.
                .accessibilityElement(children: .contain)
                .accessibilityLabel(image.altText)
                .accessibilityValue("缩放 \(Int((scale * 100).rounded()))%")
                .accessibilityHint("上下轻扫调整缩放；放大后可拖动查看")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment:
                        zoomIn(in: proxy.size)
                    case .decrement:
                        zoomOut(in: proxy.size)
                    @unknown default:
                        break
                    }
                }
                .accessibilityAction(named: "放大照片") {
                    zoomIn(in: proxy.size)
                }
                .accessibilityAction(named: "缩小照片") {
                    zoomOut(in: proxy.size)
                }
                .accessibilityAction(named: "恢复原始大小") {
                    updateTransform {
                        resetTransform()
                    }
                }
                .accessibilityIdentifier("gallery-image-\(image.id)")
                .onChange(of: proxy.size) { _, _ in
                    // A rotated or resized iPad window must immediately return
                    // to the uncropped 1x composition. Animating from the old
                    // viewport briefly preserves an invalid crop.
                    resetTransform()
                }
        }
    }

    private func magnifyGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(lastScale * value.magnification, 1), 4)
                offset = constrained(offset, scale: scale, in: size)
            }
            .onEnded { _ in
                if scale < 1.05 {
                    updateTransform {
                        resetTransform()
                    }
                } else {
                    lastScale = scale
                    offset = constrained(offset, scale: scale, in: size)
                    lastOffset = offset
                }
            }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let proposed = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
                offset = constrained(proposed, scale: scale, in: size)
            }
            .onEnded { _ in
                offset = constrained(offset, scale: scale, in: size)
                lastOffset = offset
            }
    }

    private func constrained(_ proposed: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
        guard scale > 1 else { return .zero }
        let maximumX = max(0, size.width * (scale - 1) / 2)
        let maximumY = max(0, size.height * (scale - 1) / 2)
        return CGSize(
            width: min(max(proposed.width, -maximumX), maximumX),
            height: min(max(proposed.height, -maximumY), maximumY)
        )
    }

    private func resetTransform() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }

    private func zoomIn(in size: CGSize) {
        updateTransform {
            setScale(min(4, max(2, scale + 1)), in: size)
        }
    }

    private func zoomOut(in size: CGSize) {
        updateTransform {
            let nextScale = max(1, scale - 1)
            if nextScale < 1.05 {
                resetTransform()
            } else {
                setScale(nextScale, in: size)
            }
        }
    }

    private func setScale(_ newScale: CGFloat, in size: CGSize) {
        scale = newScale
        lastScale = newScale
        offset = constrained(offset, scale: newScale, in: size)
        lastOffset = offset
    }

    private func updateTransform(_ updates: () -> Void) {
        if reduceMotion {
            updates()
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                updates()
            }
        }
    }
}
