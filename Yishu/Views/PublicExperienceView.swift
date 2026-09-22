import SwiftUI

/// Guest browsing owns neither PortfolioStore nor any account/favourites store.
/// Only administrator-selected public derivatives can enter this hierarchy.
struct PublicExperienceView: View {
    @Environment(\.appServiceEnvironment) private var environment
    let onMemberAccess: () -> Void

    var body: some View {
        PublicExperienceContent(environment: environment, onMemberAccess: onMemberAccess)
            .id(environment)
    }
}

private struct PublicExperienceContent: View {
    @StateObject private var store: PublicExperienceStore
    @State private var isForeground = true
    @State private var search = ""
    let onMemberAccess: () -> Void

    init(environment: AppServiceEnvironment, onMemberAccess: @escaping () -> Void) {
#if DEBUG
        _store = StateObject(wrappedValue: PublicExperienceStore.forPreview(environment: environment))
#else
        _store = StateObject(wrappedValue: PublicExperienceStore(environment: environment))
#endif
        self.onMemberAccess = onMemberAccess
    }

    private var filteredAlbums: [PublicExperienceAlbum] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.albums.filter { query.isEmpty || ($0.title + " " + $0.subtitle).localizedStandardContains(query) }
    }

    var body: some View {
        AppNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("公开精选")
                            .font(.system(.largeTitle, design: .serif))
                            .accessibilityAddTraits(.isHeader)
                        Text("无需注册，先看一组光影。")
                            .font(.body)
                        Text("这里仅展示明确公开的精选照片。完整相册、消息与其他授权内容保留在审批专区。")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    TextField("搜索公开相册", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("public-search")
                    catalog
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("易姝 · 短剧演员 / 模特 / 视频创作者")
                            .font(.headline)
                        Text("专注于短剧表演、时尚摄影与艺术创作。通过影像，记录不同角色与情绪。")
                            .font(.body)
                            .foregroundStyle(AppTheme.muted)
                        NavigationLink { PrivacyPolicyView() } label: {
                            Label("隐私政策", systemImage: "hand.raised")
                                .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("public-privacy-entry")
                    }
                }
                .padding(20)
                .frame(maxWidth: 960, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(AppTheme.ink.ignoresSafeArea())
            .foregroundStyle(AppTheme.warmWhite)
            .scrollIndicators(.hidden)
            .refreshable { await store.load() }
            .navigationTitle("公开体验")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("public-experience-root")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onMemberAccess) {
                        Label("审批专区", systemImage: "person.crop.circle")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("public-member-entry")
                }
            }
            .navigationDestination(for: Int.self) { id in
                PublicAlbumView(store: store, albumID: id)
            }
        }
        .task(id: isForeground) {
            guard isForeground else { return }
            // Withdrawal is checked while a visitor stays in an album or its
            // full-screen viewer, not only after returning to the first page.
            while !Task.isCancelled {
                await store.load()
                do { try await Task.sleep(for: .seconds(60)) }
                catch { return }
            }
        }
        // This page can live inside an independently hosted secure canvas.
        // Its initial SwiftUI scenePhase is not a reliable first-load signal.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            isForeground = false
            store.invalidate()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            isForeground = true
        }
    }

    @ViewBuilder private var catalog: some View {
        if store.isLoading && store.albums.isEmpty {
            ProgressView("正在载入公开精选…")
                .frame(maxWidth: .infinity, minHeight: 120)
        } else if let error = store.errorMessage {
            ContentUnavailableView {
                Label("公开精选暂不可用", systemImage: "wifi.exclamationmark")
            } description: { Text(error) } actions: {
                Button("重试") { Task { await store.load() } }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("public-catalog-retry")
            }
        } else if store.hasLoaded && store.albums.isEmpty {
            ContentUnavailableView("精选作品准备中", systemImage: "photo.on.rectangle",
                description: Text("管理员尚未发布公开照片。你仍可查看隐私说明，或进入审批专区提交访问申请。"))
                .accessibilityIdentifier("public-catalog-empty")
        } else if filteredAlbums.isEmpty && !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 20)], spacing: 24) {
                ForEach(filteredAlbums) { album in
                    NavigationLink(value: album.id) {
                        VStack(alignment: .leading, spacing: 10) {
                            ArtworkImage(url: album.images.first?.url, contentMode: .fit)
                                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                                .accessibilityHidden(true)
                            Text(album.title)
                                .font(.system(.title3, design: .serif))
                            if !album.subtitle.isEmpty {
                                Text(album.subtitle).font(.footnote).foregroundStyle(AppTheme.muted)
                            }
                            Text("公开精选 · \(album.images.count) 张")
                                .font(.caption).foregroundStyle(AppTheme.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("public-album-\(album.id)")
                }
            }
        }
    }
}

private struct PublicAlbumView: View {
    @ObservedObject var store: PublicExperienceStore
    let albumID: Int
    @State private var selectedImage: PublicExperienceImage?
    private var album: PublicExperienceAlbum? { store.albums.first { $0.id == albumID } }

    var body: some View {
        ScrollView {
            if let album {
                VStack(alignment: .leading, spacing: 20) {
                    Text(album.subtitle).foregroundStyle(AppTheme.muted)
                    ForEach(album.images) { image in
                        Button { selectedImage = image } label: {
                            ArtworkImage(url: image.url, contentMode: .fit)
                                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(image.altText.isEmpty ? "打开精选照片" : image.altText)
                        .accessibilityIdentifier("public-photo-\(image.id)")
                    }
                    Text("仅展示本相册已公开的精选照片。")
                        .font(.footnote).foregroundStyle(AppTheme.muted)
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            } else {
                ContentUnavailableView("此精选已更新", systemImage: "photo",
                    description: Text("请返回公开体验页重新加载。"))
            }
        }
        .background(AppTheme.ink.ignoresSafeArea())
        .navigationTitle(album?.title ?? "公开精选")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $selectedImage) { image in
            SecureCaptureSurface(owner: .fullScreenPresentation, onExit: { selectedImage = nil }) {
                PublicGalleryView(store: store, albumID: albumID, initialImageID: image.id,
                                  onClose: { selectedImage = nil })
            }
        }
    }
}

private struct PublicGalleryView: View {
    @ObservedObject var store: PublicExperienceStore
    let albumID: Int
    let onClose: () -> Void
    @State private var selection: Int

    init(store: PublicExperienceStore, albumID: Int, initialImageID: Int, onClose: @escaping () -> Void) {
        self.store = store
        self.albumID = albumID
        self.onClose = onClose
        _selection = State(initialValue: initialImageID)
    }

    private var images: [PublicExperienceImage] { store.albums.first { $0.id == albumID }?.images ?? [] }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }
                .accessibilityLabel("关闭图片")
                .accessibilityIdentifier("public-gallery-close")
                Spacer()
                Text("\((images.firstIndex { $0.id == selection } ?? 0) + 1) / \(images.count)")
                    .font(.caption.monospacedDigit())
                    .accessibilityIdentifier("public-gallery-counter")
            }
            .padding(.horizontal, 16)
            if let first = images.first {
                TabView(selection: Binding(
                    get: { images.contains(where: { $0.id == selection }) ? selection : first.id },
                    set: { selection = $0 }
                )) {
                    ForEach(images) { image in
                        // Both resolutions deliberately point to the SAME
                        // published derivative, never the member original.
                        ZoomableArtwork(image: PortfolioImage(id: image.id, url: image.url,
                            fullSizeURL: image.url, altText: image.altText))
                            .tag(image.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            Text("双指缩放 · 左右翻页").font(.caption).padding(.bottom, 12)
        }
        .foregroundStyle(.white)
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .onChange(of: images.map(\.id), initial: true) { _, ids in
            if ids.isEmpty { onClose() }
        }
    }
}
