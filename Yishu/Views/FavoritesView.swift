import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var recentlyViewed: RecentlyViewedStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedEntry: FavoriteEntry?
    @State private var selectedSection: LibrarySection = .favorites
    @State private var showClearHistoryConfirmation = false
    let showPortfolio: () -> Void

    init(showPortfolio: @escaping () -> Void = {}) {
        self.showPortfolio = showPortfolio
    }

    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }
        if horizontalSizeClass == .regular {
            return Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)
        }
        return [GridItem(.adaptive(minimum: 155, maximum: 320), spacing: 3)]
    }

    private var entries: [FavoriteEntry] {
        store.portfolios.flatMap { portfolio in
            portfolio.images
                .filter(favorites.contains)
                .map { FavoriteEntry(portfolio: portfolio, image: $0) }
        }
    }

    private var recentPortfolios: [Portfolio] {
        recentlyViewed.portfolioIDs.compactMap { id in
            store.portfolios.first { $0.id == id }
        }
    }

    private var favoritesShareText: String {
        let groups = store.portfolios.compactMap { portfolio -> String? in
            let count = portfolio.images.filter(favorites.contains).count
            guard count > 0 else { return nil }
            return "\(portfolio.title) · \(count) 张"
        }
        return (
            ["我收藏了易姝的 \(entries.count) 张影像："]
                + groups
                + ["更多作品请在 Hi，梳子 App 内浏览。"]
        ).joined(separator: "\n\n")
    }

    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                        .padding(.horizontal, 20)

                    sectionPicker
                        .padding(.horizontal, 20)

                    if selectedSection == .favorites {
                        favoritesContent
                    } else {
                        historyContent
                    }
                }
                .padding(.bottom, 30)
            }
            .floatingTabBarScrollClearance()
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Portfolio.self) { portfolio in
            PortfolioDetailView(portfolio: portfolio)
        }
        .fullScreenCover(item: $selectedEntry) { entry in
            SecureCaptureSurface(
                owner: .fullScreenPresentation,
                onExit: { selectedEntry = nil }
            ) {
                GalleryViewer(
                    portfolio: entry.portfolio,
                    initialImage: entry.image,
                    onClose: { selectedEntry = nil }
                )
                    .environmentObject(store)
                    .environmentObject(favorites)
            }
            .statusBarHidden()
        }
        .confirmationDialog(
            "清除最近浏览记录？",
            isPresented: $showClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除记录", role: .destructive) { recentlyViewed.clear() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("收藏的照片不会受到影响。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("YOUR EDIT")
                .font(.caption2.weight(.semibold))
                .tracking(3)
                .foregroundStyle(AppTheme.gold)

            HStack(alignment: .firstTextBaseline) {
                Text("收藏")
                    .font(.system(.largeTitle, design: .serif))
                    .accessibilityIdentifier("favorites-heading")
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if selectedSection == .favorites, !entries.isEmpty {
                    ShareLink(item: favoritesShareText) {
                        Label("分享片单", systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                            .font(.body.weight(.medium))
                            .foregroundStyle(AppTheme.gold)
                            .frame(width: 44, height: 44)
                            .background(.white.opacity(0.06), in: Circle())
                    }
                    .accessibilityLabel("分享收藏片单")
                } else if selectedSection == .history, !recentPortfolios.isEmpty {
                    Button { showClearHistoryConfirmation = true } label: {
                        Image(systemName: "trash")
                            .font(.body.weight(.medium))
                            .foregroundStyle(AppTheme.muted)
                            .frame(width: 44, height: 44)
                            .background(.white.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除最近浏览记录")
                }
            }

            Text(selectedSection == .favorites
                 ? "你留下的 \(entries.count) 帧影像"
                 : "最近看过的 \(recentPortfolios.count) 组作品")
                .font(.subheadline)
                .foregroundStyle(AppTheme.muted)
        }
    }

    private var sectionPicker: some View {
        HStack(spacing: 4) {
            ForEach(LibrarySection.allCases) { section in
                Button { selectedSection = section } label: {
                    Text(section.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(selectedSection == section ? AppTheme.ink : AppTheme.muted)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            selectedSection == section ? AppTheme.warmWhite : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
            }
        }
        .padding(3)
        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private var favoritesContent: some View {
        if entries.isEmpty {
            emptyState(
                icon: "heart",
                title: "还没有收藏",
                message: "打开任意作品，点亮心形即可留在这里。",
                actionTitle: "去看作品",
                action: showPortfolio
            )
        } else {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(entries) { entry in
                    Button { selectedEntry = entry } label: {
                        ZStack(alignment: .bottomLeading) {
                            ArtworkImage(url: entry.image.url)
                                .aspectRatio(3 / 4, contentMode: .fit)
                                .frame(maxWidth: .infinity)
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.72)],
                                startPoint: .center,
                                endPoint: .bottom
                            )
                            HStack {
                                Text(entry.portfolio.title)
                                Spacer()
                            }
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(10)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(entry.image.altText)
                }
            }
            .padding(.horizontal, 3)
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if recentPortfolios.isEmpty {
            emptyState(
                icon: "clock.arrow.circlepath",
                title: "还没有浏览记录",
                message: "进入任意相册后，最近看过的作品会保留在这里。",
                actionTitle: "浏览相册",
                action: showPortfolio
            )
        } else {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(recentPortfolios) { portfolio in
                    NavigationLink(value: portfolio) {
                        ZStack(alignment: .bottomLeading) {
                            ArtworkImage(url: portfolio.coverURL)
                                .aspectRatio(3 / 4, contentMode: .fit)
                                .frame(maxWidth: .infinity)
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.82)],
                                startPoint: .center,
                                endPoint: .bottom
                            )
                            VStack(alignment: .leading, spacing: 4) {
                                Text(portfolio.eyebrow)
                                    .font(.caption2.weight(.semibold))
                                    .tracking(1)
                                    .foregroundStyle(AppTheme.gold)
                                Text(portfolio.title)
                                    .font(.system(.title3, design: .serif))
                            }
                            .foregroundStyle(.white)
                            .padding(12)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 3)
        }
    }

    private func emptyState(
        icon: String,
        title: String,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.largeTitle.weight(.regular))
                .foregroundStyle(AppTheme.gold)
            Text(title)
                .font(.system(.title, design: .serif))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(AppTheme.muted)
                .multilineTextAlignment(.center)
            Button(actionTitle, action: action)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
                .padding(.horizontal, 22)
                .frame(minHeight: 44)
                .background(AppTheme.warmWhite, in: Capsule())
                .accessibilityIdentifier("library-open-portfolio")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 36)
        .padding(.vertical, 76)
    }

}

private enum LibrarySection: String, CaseIterable, Identifiable {
    case favorites
    case history

    var id: String { rawValue }
    var title: String { self == .favorites ? "收藏照片" : "最近浏览" }
}

private struct FavoriteEntry: Identifiable {
    let portfolio: Portfolio
    let image: PortfolioImage
    var id: Int { image.id }
}
