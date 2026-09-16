import SwiftUI
import UIKit

/// Captions can cross a fitted photograph's letterbox area. Match those
/// unpainted areas to the chosen theme without adding a backdrop to the photo.
@MainActor
struct PortfolioCaptionPalette {
    let theme: AppColorTheme
    static var current: Self { Self(theme: AppearanceStore.shared.theme) }
    private var usesDarkGlyphs: Bool { theme.colorScheme == .light }

    var title: Color { usesDarkGlyphs ? theme.palette.text.color : .white }
    var subtitle: Color { usesDarkGlyphs ? theme.palette.secondary.color : .white.opacity(0.92) }
    var accent: Color { usesDarkGlyphs ? theme.palette.accent.color : MediaTheme.gold }
    var ordinal: Color { usesDarkGlyphs ? theme.palette.text.color : .white.opacity(0.84) }
    var shadow: Color { usesDarkGlyphs ? .white.opacity(0.85) : .black.opacity(0.72) }
    var outline: Color { usesDarkGlyphs ? .white : .black }
}

/// Keep the photograph visible right up to the glyphs. This modifier must not
/// paint a rectangle, material or gradient behind an album caption.
struct PortfolioCaptionLegibility: ViewModifier {
    var palette: PortfolioCaptionPalette? = nil

    func body(content: Content) -> some View {
        let colors = palette ?? .current
        // A blurred drop shadow disappears against pale or detailed photos.
        // Trace only the glyphs; leave the photograph and caption frame clear.
        content
            .shadow(color: colors.outline, radius: 0, x: 0.75, y: 0)
            .shadow(color: colors.outline, radius: 0, x: -0.75, y: 0)
            .shadow(color: colors.outline, radius: 0, x: 0, y: 0.75)
            .shadow(color: colors.outline, radius: 0, x: 0, y: -0.75)
            .shadow(color: colors.shadow, radius: 2, x: 0, y: 1)
    }
}

struct PortfolioGridView: View {
    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var admin: AdminSessionStore
    @EnvironmentObject private var fanAccount: FanAccountStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var searchText = ""
    @State private var availableWidth: CGFloat = 0

    private var usesNativeSearchToolbar: Bool {
        // iPadOS 27 changes the root safe-area inset when a hidden navigation
        // bar reappears after a detail pop. Let the navigation bar own the
        // existing search control so it keeps one layout through push/pop.
        if #available(iOS 27.0, *) { return UIDevice.current.userInterfaceIdiom == .pad }
        return false
    }

    private var searchTopPadding: CGFloat {
        // Landscape phones have no status-bar inset. Do not position the
        // input/cancel accessibility frames above the window's top edge.
        verticalSizeClass == .compact ? 8 : (horizontalSizeClass == .regular ? -1 : 0)
    }

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
        portfolioContent
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
            .toolbar {
                if usesNativeSearchToolbar {
                    ToolbarItem(placement: .principal) {
                        PortfolioSearchBar(text: $searchText, usesNativeToolbar: true)
                            .frame(width: max(0, availableWidth - 40))
                            .background {
#if DEBUG
                                if ProcessInfo.processInfo.arguments.contains("-trace-portfolio-layout-for-testing") {
                                    PortfolioLayoutTrace()
                                }
#endif
                            }
                    }
                }
            }
            .toolbar(usesNativeSearchToolbar ? .visible : .hidden, for: .navigationBar)
    }

    private var portfolioContent: some View {
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
                        Group {
                            if store.portfolios.isEmpty {
                                ContentUnavailableView("暂无可见相册", systemImage: "photo.on.rectangle",
                                    description: Text("相册发布后会在这里显示，可下拉刷新。"))
                            } else {
                                ContentUnavailableView.search(text: searchText)
                            }
                        }
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
            // Keep the pinned search inset's geometry stable during push/pop,
            // but let moving artwork remain visible behind its material.
            .scrollClipDisabled()
            .refreshable { await refreshContent() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Portfolio.self) { portfolio in
            PortfolioDetailView(portfolio: portfolio)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !usesNativeSearchToolbar {
                PortfolioSearchBar(text: $searchText)
                    .padding(.horizontal, 20)
                    .padding(.top, searchTopPadding)
                    .padding(.bottom, 10)
                    .background(.ultraThinMaterial)
                    .background {
#if DEBUG
                        if ProcessInfo.processInfo.arguments.contains("-trace-portfolio-layout-for-testing") {
                            PortfolioLayoutTrace()
                        }
#endif
                    }
            }
        }
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

#if DEBUG
/// Records geometry only (no pixels or user data), including intermediate
/// navigation/layout passes that a final-frame screenshot cannot reveal.
private struct PortfolioLayoutTrace: UIViewRepresentable {
    func makeUIView(context: Context) -> PortfolioLayoutTraceView { PortfolioLayoutTraceView() }
    func updateUIView(_ view: PortfolioLayoutTraceView, context: Context) { }
}

private final class PortfolioLayoutTraceView: UIView {
    private var frames: [CGRect] = []
    private var displayLink: CADisplayLink?
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "portfolio-layout-trace"
        accessibilityLabel = "作品顶部布局轨迹"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        if window != nil {
            let link = CADisplayLink(target: self, selector: #selector(sample))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }
    override func layoutSubviews() { super.layoutSubviews(); sample() }
    @objc private func sample() {
        guard let window, bounds.width > window.bounds.width * 0.7 else { return }
        let frame = convert(bounds, to: window).integral
        // Exclude horizontal push/pop movement; detect unintended vertical
        // reflow once the page is aligned inside the current app window.
        guard frame.minX >= 0, frame.maxX <= window.bounds.maxX,
              frames.last != frame, frames.count < 120 else { return }
        frames.append(frame)
        accessibilityValue = frames.map { "\(Int($0.minY)),\(Int($0.height))" }.joined(separator: ";")
    }
}
#endif

private struct PortfolioSearchBar: View {
    @Binding var text: String
    var usesNativeToolbar = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @FocusState private var isFocused: Bool

    private var showsCancel: Bool {
        // A toolbar-hosted field can accept keyboard input without reporting
        // FocusState on iPadOS 27. A nonempty query must still be cancellable.
        isFocused || (usesNativeToolbar && !text.isEmpty)
    }

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

            if showsCancel {
                Button("取消") {
                    text = ""
                    isFocused = false
                    if usesNativeToolbar {
                        // Public responder action also dismisses the keyboard
                        // when the system omitted the FocusState transition.
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                        to: nil, from: nil, for: nil)
                    }
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: showsCancel)
    }
}

private struct PortfolioGridCard: View {
    let portfolio: Portfolio

    private var editorialEyebrow: String {
        portfolio.eyebrow.replacingOccurrences(of: " · ", with: "\n")
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ArtworkImage(url: portfolio.coverURL, showsRetryButton: false)
                .aspectRatio(3 / 4, contentMode: .fit)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 5) {
                Text(editorialEyebrow)
                    .font(.caption2.weight(.semibold))
                    .tracking(0.7)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .foregroundStyle(PortfolioCaptionPalette.current.accent)
                    .accessibilityLabel(portfolio.eyebrow)
                Text(portfolio.title)
                    .font(.system(.title3, design: .serif))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(PortfolioCaptionPalette.current.title)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)

        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

struct PortfolioDetailView: View {
    let portfolio: Portfolio
    @Environment(\.dismiss) private var dismiss
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
        store.portfolios.first { $0.id == portfolio.id } ?? Portfolio(
            id: portfolio.id, title: portfolio.title, subtitle: portfolio.subtitle,
            eyebrow: portfolio.eyebrow, slug: portfolio.slug, websiteURL: portfolio.websiteURL,
            coverURL: nil, images: [], totalImageCount: 0, isVisible: false)
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
        .onChange(of: store.portfolios.map(\.id)) { _, ids in
            if !ids.contains(portfolio.id) {
                selectedImage = nil
                dismiss()
            }
        }
        .navigationTitle(currentPortfolio.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .stableDetailTabBar()
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

            VStack(alignment: .leading, spacing: 10) {
                Text(portfolio.eyebrow)
                    .font(.caption2.weight(.semibold))
                    .tracking(2)
                    .foregroundStyle(PortfolioCaptionPalette.current.accent)
                Text(portfolio.title)
                    .font(.system(.largeTitle, design: .serif))
                Text(portfolio.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(PortfolioCaptionPalette.current.subtitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(PortfolioCaptionPalette.current.title)
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
                .foregroundStyle(PortfolioCaptionPalette.current.ordinal)
                .modifier(PortfolioCaptionLegibility())
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
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
        // ArtworkImage owns its loading/error placeholder. Do not leave an
        // opaque placeholder or black tint behind an already loaded portrait:
        // aspect-fit margins must reveal the page, not form another dark panel.
        // The outer open-photo button still owns taps after a loading failure.
        ArtworkImage(url: url, contentMode: .fit, showsRetryButton: false)
            .clipped()
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

enum GallerySelection {
    static func resolve(_ requestedID: Int, imageIDs: [Int]) -> Int? {
        imageIDs.contains(requestedID) ? requestedID : imageIDs.first
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
        accessibleImages.first { $0.id == resolvedSelection }
    }

    private var selectedIndex: Int {
        guard let index = accessibleImages.firstIndex(where: { $0.id == resolvedSelection }) else { return 0 }
        return index + 1
    }

    private var resolvedSelection: Int? {
        GallerySelection.resolve(selection, imageIDs: accessibleImages.map(\.id))
    }

    private var accessibleImages: [PortfolioImage] {
        store.portfolios.first(where: { $0.id == portfolio.id })?.images ?? []
    }

    var body: some View {
        GeometryReader { viewport in
            let images = accessibleImages
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    galleryToolbar
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    // Use the same collection snapshot for pages and the
                    // binding. Never hand iOS 27 a stale or empty selection
                    // while a manifest/permission update removes a photo.
                    if let firstID = images.first?.id {
                        TabView(selection: Binding(
                            get: { GallerySelection.resolve(selection, imageIDs: images.map(\.id)) ?? firstID },
                            set: { newID in
                                guard accessibleImages.contains(where: { $0.id == newID }) else { return }
                                selection = newID
                            }
                        )) {
                            ForEach(images) { image in
                                ZoomableArtwork(image: image)
                                    .tag(image.id)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .padding(.horizontal, galleryHorizontalInset(in: viewport.size))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityHidden(true)
                    }

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
                    ),
                    environment: store.serviceEnvironment
                )
            }
        }
        .statusBarHidden()
        .environment(\.colorScheme, .dark)
        .onChange(of: accessibleImages.map(\.id), initial: true) { _, imageIDs in
            if imageIDs.isEmpty { onClose(); return }
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
        guard let index = accessibleImages.firstIndex(where: { $0.id == resolvedSelection }) else {
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
    let serviceEnvironment: AppServiceEnvironment

    init(image: PortfolioImage, targetSize: CGSize, environment: AppServiceEnvironment = .production) {
        self.image = image
        self.targetSize = targetSize
        serviceEnvironment = environment
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.image == rhs.image && lhs.targetSize == rhs.targetSize && lhs.serviceEnvironment == rhs.serviceEnvironment
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
        .environment(\.appServiceEnvironment, serviceEnvironment)
    }
}

private struct ZoomableArtwork: UIViewControllerRepresentable {
    let image: PortfolioImage
    @Environment(\.appServiceEnvironment) private var serviceEnvironment

    func makeUIViewController(context: Context) -> GalleryZoomViewController {
        GalleryZoomViewController(image: image, environment: serviceEnvironment)
    }

    func updateUIViewController(_ controller: GalleryZoomViewController, context: Context) {
        controller.update(image: image, environment: serviceEnvironment)
    }
}

/// Keep high-frequency pinch and pan work inside UIScrollView. Updating SwiftUI
/// @State for every finger movement invalidates the hosted image hierarchy.
final class GalleryZoomViewController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let scrollView = GalleryZoomScrollView()
    private let zoomCanvas = UIView()
    private var image: PortfolioImage
    private(set) var serviceEnvironment: AppServiceEnvironment
    private var viewportSize: CGSize = .zero
    private var artworkHost: UIHostingController<EquatableView<ProgressiveGalleryArtwork>>?
    private var zoomAccessibility: GalleryZoomAccessibilityElement?
    private var pinchStartScale: CGFloat = 1
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))

#if DEBUG
    private(set) var contentUpdateCount = 0
    private var doubleTapCount = 0
#endif

    init(image: PortfolioImage, environment: AppServiceEnvironment = .production) {
        self.image = image
        serviceEnvironment = environment
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
            image: image, targetSize: .zero, environment: serviceEnvironment
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
        // Hosted controls must win accessibility hit-testing over the virtual
        // full-viewport photo. Otherwise Retry exists but cannot be activated.
        scrollView.accessibilityElements = [host.view as Any, accessiblePhoto]
        zoomAccessibility = accessiblePhoto
        updateAccessibility()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard size.width > 0, size.height > 0, size != viewportSize else { return }
        let previousScale = scrollView.zoomScale
        let preservesComposition = viewportSize.width > 0 && viewportSize.height > 0
            && (viewportSize.width > viewportSize.height) == (size.width > size.height)
        let focus = preservesComposition ? CGPoint(
            x: (scrollView.contentOffset.x + viewportSize.width / 2) / (viewportSize.width * previousScale),
            y: (scrollView.contentOffset.y + viewportSize.height / 2) / (viewportSize.height * previousScale)
        ) : CGPoint(x: 0.5, y: 0.5)
        viewportSize = size
        scrollView.frame = view.bounds
        // Reset the canvas transform only while changing its base geometry.
        // Status-bar/safe-area settling must not discard a user's pinch or pan.
        // A change between portrait and landscape still shows the complete 1x image.
        scrollView.setZoomScale(1, animated: false)
        zoomCanvas.frame = CGRect(origin: .zero, size: size)
        artworkHost?.view.frame = zoomCanvas.bounds
        scrollView.contentSize = size
        updateArtwork()
        let restoredScale = preservesComposition ? previousScale : 1
        scrollView.setZoomScale(restoredScale, animated: false)
        scrollView.contentOffset = clampedContentOffset(CGPoint(
            x: focus.x * size.width * restoredScale - size.width / 2,
            y: focus.y * size.height * restoredScale - size.height / 2
        ))
        if pinch.state == .began || pinch.state == .changed {
            // Continue from the resized geometry, not from the scale captured
            // before rotation. Keep the recognizer and current touches alive.
            pinchStartScale = restoredScale / max(pinch.scale, 0.001)
        }
        updateAccessibility()
    }

    func update(image: PortfolioImage, environment: AppServiceEnvironment = .production) {
        guard self.image != image || serviceEnvironment != environment else { return }
        self.image = image
        serviceEnvironment = environment
        guard isViewLoaded else { return }
        scrollView.setZoomScale(1, animated: false)
        scrollView.contentOffset = .zero
        updateArtwork()
        updateAccessibility()
    }

    private func updateArtwork() {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        artworkHost?.rootView = ProgressiveGalleryArtwork(
            image: image, targetSize: viewportSize, environment: serviceEnvironment
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
            scrollView.contentOffset = clampedContentOffset(CGPoint(
                x: point.x * scale - anchor.x,
                y: point.y * scale - anchor.y
            ))
        case .ended, .cancelled, .failed:
            if scrollView.zoomScale < 1.05 { scrollView.setZoomScale(1, animated: false) }
            updateAccessibility()
        default:
            break
        }
    }

    private func clampedContentOffset(_ proposed: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(0, proposed.x), max(0, scrollView.contentSize.width - scrollView.bounds.width)),
            y: min(max(0, proposed.y), max(0, scrollView.contentSize.height - scrollView.bounds.height))
        )
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        (gestureRecognizer === pinch && otherGestureRecognizer === scrollView.panGestureRecognizer)
            || (otherGestureRecognizer === pinch && gestureRecognizer === scrollView.panGestureRecognizer)
    }

    private func updateAccessibility() {
        zoomAccessibility?.accessibilityIdentifier = "gallery-image-\(image.id)"
        zoomAccessibility?.accessibilityLabel = image.altText
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-trace-gallery-gestures-for-testing") {
            zoomAccessibility?.accessibilityLabel = "\(image.altText); doubleTaps=\(doubleTapCount)"
            zoomAccessibility?.accessibilityHint = "doubleTaps=\(doubleTapCount); viewport=\(viewportSize); offset=\(scrollView.contentOffset)"
        }
#endif
    }

    private func setZoom(_ scale: CGFloat) {
        scrollView.setZoomScale(
            min(4, max(1, scale)),
            animated: !UIAccessibility.isReduceMotionEnabled
        )
        updateAccessibility()
    }

    @objc private func toggleZoom() {
#if DEBUG
        doubleTapCount += 1
#endif
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

    // UIKit owns the zoom transform. Read its current value instead of a
    // snapshot captured before an animation or gesture-end callback completes.
    // This does not invalidate SwiftUI or reload artwork during a pinch.
    override var accessibilityValue: String? {
        get {
            guard let scrollView else { return nil }
            return "缩放 \(Int((scrollView.zoomScale * 100).rounded()))%"
        }
        set { }
    }

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
