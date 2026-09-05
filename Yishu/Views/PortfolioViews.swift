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
                    .stroke(AppTheme.line, lineWidth: 1)
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
                    .foregroundStyle(MediaTheme.gold)
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
            .statusBarHidden()
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
                colors: [.clear, MediaTheme.ink.opacity(0.18), MediaTheme.ink.opacity(0.96)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 10) {
                Text(portfolio.eyebrow)
                    .font(.caption2.weight(.semibold))
                    .tracking(2)
                    .foregroundStyle(MediaTheme.gold)
                Text(portfolio.title)
                    .font(.system(.largeTitle, design: .serif))
                Text(portfolio.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.white)
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
        .environment(\.colorScheme, .dark)
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
            .tint(selected.map(favorites.contains) == true ? MediaTheme.gold : .white)
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

struct ProgressiveGalleryArtwork: View, Equatable {
    let image: PortfolioImage
    let targetSize: CGSize

    init(image: PortfolioImage, targetSize: CGSize) {
        self.image = image
        self.targetSize = targetSize
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.image == rhs.image && lhs.targetSize == rhs.targetSize
    }

    var body: some View {
        Group {
            if image.fullSizeURL == image.url {
                ArtworkImage(url: image.url, contentMode: .fit)
            } else {
                // Publish one visible image at a time. The loader's phase is
                // the sole source of readiness, including URL changes/retry.
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
                    case .empty, .failure:
                        ArtworkImage(url: image.url, contentMode: .fit)
                    @unknown default:
                        ArtworkImage(url: image.url, contentMode: .fit)
                    }
                }
            }
        }
        .frame(width: targetSize.width, height: targetSize.height)
        .clipped()
    }
}

private struct ZoomableArtwork: UIViewControllerRepresentable {
    let image: PortfolioImage

    func makeUIViewController(context: Context) -> GalleryZoomViewController {
        GalleryZoomViewController(image: image)
    }

    func updateUIViewController(_ controller: GalleryZoomViewController, context: Context) {
        controller.update(image: image)
    }
}

/// Keep high-frequency pinch and pan work inside UIScrollView. Updating SwiftUI
/// @State for every finger movement invalidates the hosted image hierarchy.
final class GalleryZoomViewController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let scrollView = GalleryZoomScrollView()
    private let zoomCanvas = UIView()
    private var image: PortfolioImage
    private var viewportSize: CGSize = .zero
    private var artworkHost: UIHostingController<EquatableView<ProgressiveGalleryArtwork>>?
    private var zoomAccessibility: GalleryZoomAccessibilityElement?
    private var pinchStartScale: CGFloat = 1
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))

#if DEBUG
    private(set) var contentUpdateCount = 0
#endif

    init(image: PortfolioImage) {
        self.image = image
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scrollView.backgroundColor = .clear
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = false
        scrollView.bounces = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delaysContentTouches = false
        // Drive zoom explicitly through UIKit, keeping the image host out of
        // SwiftUI's per-event update path and retaining a stable focal point.
        scrollView.pinchGestureRecognizer?.isEnabled = false
        pinch.delegate = self
        scrollView.addGestureRecognizer(pinch)
        view.addSubview(scrollView)
        zoomCanvas.backgroundColor = .clear
        scrollView.addSubview(zoomCanvas)

        let host = UIHostingController(rootView: ProgressiveGalleryArtwork(
            image: image, targetSize: .zero
        ).equatable())
        host.view.backgroundColor = .clear
        addChild(host)
        // Zoom a plain UIKit canvas, not UIHostingController's managed root
        // view: SwiftUI can restore that root view's transform during layout.
        zoomCanvas.addSubview(host.view)
        host.didMove(toParent: self)
        artworkHost = host

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(doubleTap)

        let accessiblePhoto = GalleryZoomAccessibilityElement(
            accessibilityContainer: scrollView
        )
        accessiblePhoto.scrollView = scrollView
        accessiblePhoto.controller = self
        accessiblePhoto.accessibilityTraits = [.image, .adjustable]
        accessiblePhoto.accessibilityHint = "上下轻扫调整缩放；放大后可拖动查看"
        accessiblePhoto.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "放大照片", target: self, selector: #selector(zoomIn)),
            UIAccessibilityCustomAction(name: "缩小照片", target: self, selector: #selector(zoomOut)),
            UIAccessibilityCustomAction(name: "恢复原始大小", target: self, selector: #selector(resetZoom)),
        ]
        // Preserve access to the hosted retry button, rather than collapsing
        // the entire scroll view into a single accessibility element.
        scrollView.isAccessibilityElement = false
        scrollView.accessibilityElements = [accessiblePhoto, host.view as Any]
        zoomAccessibility = accessiblePhoto
        updateAccessibility()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard size.width > 0, size.height > 0, size != viewportSize else { return }
        viewportSize = size
        scrollView.frame = view.bounds
        // Rotation/window resizing returns to the complete 1x composition.
        scrollView.setZoomScale(1, animated: false)
        zoomCanvas.frame = CGRect(origin: .zero, size: size)
        artworkHost?.view.frame = zoomCanvas.bounds
        scrollView.contentSize = size
        scrollView.contentOffset = .zero
        updateArtwork()
        updateAccessibility()
    }

    func update(image: PortfolioImage) {
        guard self.image != image else { return }
        self.image = image
        guard isViewLoaded else { return }
        scrollView.setZoomScale(1, animated: false)
        scrollView.contentOffset = .zero
        updateArtwork()
        updateAccessibility()
    }

    private func updateArtwork() {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        artworkHost?.rootView = ProgressiveGalleryArtwork(
            image: image, targetSize: viewportSize
        ).equatable()
#if DEBUG
        contentUpdateCount += 1
#endif
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        zoomCanvas
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        if scrollView.zoomScale < 1.05 { scrollView.setZoomScale(1, animated: false) }
        updateAccessibility()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartScale = scrollView.zoomScale
        case .changed:
            let point = gesture.location(in: zoomCanvas)
            let location = gesture.location(in: scrollView)
            let anchor = CGPoint(
                x: location.x - scrollView.contentOffset.x,
                y: location.y - scrollView.contentOffset.y
            )
            let scale = min(4, max(1, pinchStartScale * gesture.scale))
            scrollView.setZoomScale(scale, animated: false)
            scrollView.contentOffset = CGPoint(
                x: min(max(0, point.x * scale - anchor.x), max(0, scrollView.contentSize.width - scrollView.bounds.width)),
                y: min(max(0, point.y * scale - anchor.y), max(0, scrollView.contentSize.height - scrollView.bounds.height))
            )
        case .ended, .cancelled, .failed:
            if scrollView.zoomScale < 1.05 { scrollView.setZoomScale(1, animated: false) }
            updateAccessibility()
        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        (gestureRecognizer === pinch && otherGestureRecognizer === scrollView.panGestureRecognizer)
            || (otherGestureRecognizer === pinch && gestureRecognizer === scrollView.panGestureRecognizer)
    }

    private func updateAccessibility() {
        zoomAccessibility?.accessibilityIdentifier = "gallery-image-\(image.id)"
        zoomAccessibility?.accessibilityLabel = image.altText
        zoomAccessibility?.accessibilityValue = "缩放 \(Int((scrollView.zoomScale * 100).rounded()))%"
    }

    private func setZoom(_ scale: CGFloat) {
        scrollView.setZoomScale(
            min(4, max(1, scale)),
            animated: !UIAccessibility.isReduceMotionEnabled
        )
        updateAccessibility()
    }

    @objc private func toggleZoom() {
        setZoom(scrollView.zoomScale > 1.01 ? 1 : 2)
    }

    @objc @discardableResult func zoomIn() -> Bool {
        setZoom(max(2, scrollView.zoomScale + 1))
        return true
    }

    @objc @discardableResult func zoomOut() -> Bool {
        setZoom(scrollView.zoomScale - 1)
        return true
    }

    @objc @discardableResult func resetZoom() -> Bool {
        setZoom(1)
        return true
    }
}

final class GalleryZoomScrollView: UIScrollView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            // Let the outer pager receive swipes at 1x, without toggling a
            // built-in recognizer while UIScrollView is processing a pinch.
            return zoomScale > 1.01
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

private final class GalleryZoomAccessibilityElement: UIAccessibilityElement {
    weak var scrollView: UIScrollView?
    weak var controller: GalleryZoomViewController?

    override var accessibilityFrame: CGRect {
        get {
            guard let scrollView else { return .zero }
            return UIAccessibility.convertToScreenCoordinates(scrollView.bounds, in: scrollView)
        }
        set { }
    }

    override func accessibilityIncrement() { controller?.zoomIn() }
    override func accessibilityDecrement() { controller?.zoomOut() }
}
