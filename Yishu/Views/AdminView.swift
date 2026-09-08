import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Owns the complete administrator navigation scope. Present this view as a
/// full-screen cover so child approval screens stay inside the same scope and
/// dismissing the cover can reliably lock credentials and protected content.
struct AdminAccessView: View {
    @EnvironmentObject private var admin: AdminSessionStore
    let onClose: () -> Void
    @State private var hasLockedOnEntry = false

    var body: some View {
        Group {
            if hasLockedOnEntry {
                AppNavigationStack {
                    AdminView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("关闭", action: onClose)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .accessibilityIdentifier("admin-close")
                            }
                        }
                }
            } else {
                ZStack {
                    AppTheme.ink.ignoresSafeArea()
                    ProgressView().tint(AppTheme.gold)
                }
            }
        }
        .task {
            guard !hasLockedOnEntry else { return }
            admin.lock()
            hasLockedOnEntry = true
        }
        .onDisappear {
            guard hasLockedOnEntry else { return }
            admin.lock()
        }
    }
}

enum AdminContentEditingPolicy {
    static func canEdit(isAuthenticated: Bool, hasLoadedFullManifest: Bool) -> Bool {
        isAuthenticated && hasLoadedFullManifest
    }

    static func isFullAdministratorManifest(_ manifest: AppContentManifest) -> Bool {
        guard manifest.portfolios.allSatisfy({ $0.images.count == $0.displayImageCount }) else { return false }
        // An authenticated administrator may legitimately have no configured
        // video. New servers attest the response audience, not editorial content.
        // This remains a completeness check, never a substitute for session/role checks.
        if let audience = manifest.contentAudience { return audience == .administrator }
        // Preserve the old stricter behavior until both production nodes are
        // upgraded. An explicit viewer response must never use this fallback.
        return manifest.showreel != nil
    }
}

/// Administrator previews are inspection surfaces, not the final editorial
/// crop. Keep the whole source asset visible here so an administrator can
/// verify orientation and framing before publishing. Public presentation views
/// intentionally keep their own independent fill/fit decisions.
enum AdminMediaPreviewPolicy {
    static let contentMode: ContentMode = .fit
}

/// Resolves an editable collection element by its stable identity on every
/// access. SwiftUI may keep a control alive for one render pass after its row
/// is removed or the server replaces the collection; an index-derived binding
/// would then trap while this binding safely falls back and ignores stale writes.
enum SafeIdentifiedBinding {
    static func element<Element: Identifiable>(
        for fallback: Element,
        in elements: Binding<[Element]>
    ) -> Binding<Element> where Element.ID: Equatable {
        Binding(
            get: {
                elements.wrappedValue.first { $0.id == fallback.id } ?? fallback
            },
            set: { updated in
                var current = elements.wrappedValue
                guard let index = current.firstIndex(where: { $0.id == fallback.id }) else {
                    return
                }
                current[index] = updated
                elements.wrappedValue = current
            }
        )
    }
}

struct AdminView: View {
    @EnvironmentObject private var admin: AdminSessionStore
    @EnvironmentObject private var fanAccount: FanAccountStore
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var username = "yishu_app_manager"
    @State private var applicationPassword = ""
    @State private var heroImageURLs = ContentCatalog.heroImages
    @State private var aboutPortraitURL = ContentCatalog.aboutPortraitURL
    @State private var launchPosterDrafts = ContentCatalog.launchPosters
    @State private var showreelDraft = ContentCatalog.showreel
    @State private var dramaDrafts: [DramaDraft] = ContentCatalog.dramas.map(DramaDraft.init)
    @State private var sharedDramaOldURL = ContentCatalog.hongguoURL.absoluteString
    @State private var sharedDramaNewURL = ""
    @State private var isCheckingDramaLink = false
    @State private var dramaLinkCheckMessage: String?
    @State private var tagsText = ContentCatalog.showreel.tags.joined(separator: "、")
    @State private var selectedPortfolioID: Int?
    @State private var isCreatingPortfolio = false
    @State private var newPortfolioTitle = ""
    @State private var newPortfolioSubtitle = "易姝影像作品"
    @State private var newPortfolioEyebrow = "PORTFOLIO"
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var selectedHero: PhotosPickerItem?
    @State private var selectedLaunchPoster: PhotosPickerItem?
    @State private var selectedAboutPortrait: PhotosPickerItem?
    @State private var selectedPoster: PhotosPickerItem?
    @State private var showVideoImporter = false
    @State private var pendingRemoval: PortfolioImage?
    @State private var isPublishing = false
    @State private var operationMessage: String?
    @State private var operationFailed = false
    @State private var pendingFanCount = 0
    @State private var pendingCollaborationCount = 0
    @State private var collaborationInboxEnabled = false
    @State private var hasLoadedAdministratorContent = false
    @State private var isLoadingAdministratorContent = false
    @State private var administratorContentError: String?
    @State private var administratorContentLoadID = UUID()
    @State private var activeOperationID: UUID?

    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            ScrollView {
                Group {
                    if admin.isAuthenticated {
                        if administratorEditorIsReady {
                            dashboard
                        } else {
                            administratorContentLoadingView
                        }
                    } else {
                        login
                    }
                }
                .frame(
                    maxWidth: admin.isAuthenticated ? 1_000 : 680,
                    alignment: .leading
                )
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle(admin.isAuthenticated ? "内容管理" : "管理员登录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .stableDetailTabBar()
        .themeNavigationChrome()
        .task(id: admin.isAuthenticated) {
            if admin.isAuthenticated {
                await loadAdministratorContent()
            } else {
                invalidateAdministratorContentLoad()
            }
        }
        .task(id: admin.isAuthenticated) {
            await monitorPendingCounts()
        }
        .onChange(of: admin.isAuthenticated) { _, authenticated in
            applicationPassword = ""
            if authenticated {
                Task { await refreshPendingCounts() }
            } else {
                invalidateAdministratorContentLoad()
                pendingFanCount = 0
                pendingCollaborationCount = 0
                collaborationInboxEnabled = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { applicationPassword = "" }
        }
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            Task { await uploadPortfolioPhotos(items) }
        }
        .onChange(of: selectedHero) { _, item in
            guard let item else { return }
            Task { await uploadHeroImage(item) }
        }
        .onChange(of: selectedLaunchPoster) { _, item in
            guard let item else { return }
            Task { await uploadLaunchPoster(item) }
        }
        .onChange(of: selectedAboutPortrait) { _, item in
            guard let item else { return }
            Task { await uploadAboutPortrait(item) }
        }
        .onChange(of: selectedPoster) { _, item in
            guard let item else { return }
            Task { await uploadShowreelPoster(item) }
        }
        .fileImporter(
            isPresented: $showVideoImporter,
            allowedContentTypes: [.movie],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await uploadShowreelVideo(url) }
        }
        .confirmationDialog(
            "从这个作品集中移除照片？",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("移出作品集", role: .destructive) {
                if let image = pendingRemoval { Task { await remove(image) } }
            }
            Button("取消", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("原文件仍保留在 WordPress 媒体库，可由管理员恢复。")
        }
    }

    private var administratorEditorIsReady: Bool {
        AdminContentEditingPolicy.canEdit(
            isAuthenticated: admin.isAuthenticated,
            hasLoadedFullManifest: hasLoadedAdministratorContent
        )
    }

    private var administratorContentLoadingView: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("ADMIN CONTENT")
                .font(.caption2.weight(.semibold))
                .tracking(3)
                .foregroundStyle(AppTheme.gold)
            Text("正在核对完整内容")
                .font(.system(.largeTitle, design: .serif))
                .accessibilityAddTraits(.isHeader)
            Text("编辑器会在管理员全量清单安全载入后开放，避免把粉丝权限范围内的内容误当成发布草稿。")
                .font(.subheadline)
                .foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            if isLoadingAdministratorContent || administratorContentError == nil {
                HStack(spacing: 12) {
                    ProgressView().tint(AppTheme.gold)
                    Text("正在从服务器读取管理员内容")
                }
                .font(.caption)
                .foregroundStyle(AppTheme.gold)
            }

            if let administratorContentError {
                Label(administratorContentError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(AppTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
                Button {
                    Task { await loadAdministratorContent() }
                } label: {
                    Label("重新载入完整内容", systemImage: "arrow.clockwise")
                        .adminPrimaryButton()
                }
                .disabled(isLoadingAdministratorContent)
            }

            Button("退出管理员登录") { admin.signOut() }
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
                .frame(minHeight: 44)
        }
        .padding(22)
        .padding(.top, 24)
    }

    private var login: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 10) {
                Text("ADMIN ACCESS")
                    .font(.caption2.weight(.semibold))
                    .tracking(3)
                    .foregroundStyle(AppTheme.gold)
                Text("管理员登录")
                    .font(.system(.largeTitle, design: .serif))
                    .accessibilityIdentifier("admin-login-heading")
                    .accessibilityAddTraits(.isHeader)
                Text("普通用户需先注册并通过审批。这里用于注册审批、权限分配和内容发布。")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.muted)
            }

            VStack(spacing: 14) {
                if fanAccount.administratorContext != nil {
                    Button {
                        Task { await admin.signIn(using: fanAccount) }
                    } label: {
                        Label("使用当前账号进入管理", systemImage: "person.crop.circle.badge.checkmark")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .disabled(admin.isWorking)
                    .accessibilityIdentifier("admin-use-bound-account")
                }
                TextField("管理员账号", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .accessibilityLabel("管理员账号")
                SecureField("管理员访问码", text: $applicationPassword)
                    .textContentType(.password)
                    .accessibilityLabel("管理员访问码")
                    .submitLabel(.go)
                    .onSubmit {
                        guard !admin.isWorking else { return }
                        Task {
                            await admin.signIn(
                                username: username,
                                applicationPassword: applicationPassword
                            )
                        }
                    }
                Button {
                    Task { await admin.signIn(username: username, applicationPassword: applicationPassword) }
                } label: {
                    HStack {
                        if admin.isWorking { ProgressView().tint(AppTheme.ink) }
                        Text(admin.isWorking ? "正在验证" : "安全登录")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.warmWhite, in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(AppTheme.ink)
                }
                .disabled(admin.isWorking)
            }
            .textFieldStyle(AdminTextFieldStyle())

            if let error = admin.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(AppTheme.warning)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            Label("账号与访问码仅用于本次验证，只在内存中保留；App 进入后台或 5 分钟后会自动锁定。", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
        }
        .padding(22)
        .padding(.top, 24)
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 34) {
            dashboardHeader
            fanAccessEditor
            if collaborationInboxEnabled {
                collaborationInboxEditor
            }
            launchPosterEditor
            heroEditor
            aboutPortraitEditor
            portfolioEditor
            showreelEditor
            dramaEditor
            publishControls
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 70)
    }

    private var dashboardHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CONTENT STUDIO")
                .font(.caption2.weight(.semibold))
                .tracking(3)
                .foregroundStyle(AppTheme.gold)
            Text("内容工作台")
                .font(.system(.largeTitle, design: .serif))
                .accessibilityAddTraits(.isHeader)
            HStack {
                Label("管理员模式", systemImage: "checkmark.shield")
                Spacer()
                Button("退出") { admin.signOut() }
                    .disabled(isPublishing)
                    .frame(minHeight: 44)
            }
            .font(.caption)
            .foregroundStyle(AppTheme.muted)

            if isPublishing {
                HStack(spacing: 10) {
                    ProgressView().tint(AppTheme.gold)
                    Text("正在上传或发布，请保持 App 在前台")
                }
                .font(.caption)
                .foregroundStyle(AppTheme.gold)
            } else if let operationMessage {
                Label(operationMessage, systemImage: operationFailed ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(operationFailed ? AppTheme.warning : AppTheme.gold)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    private var portfolioEditor: some View {
        AdminSection(title: "照片作品", subtitle: "新建相册、上传照片与调整内容") {
            Picker("当前相册", selection: selectedPortfolioBinding) {
                ForEach(editablePortfolios) { portfolio in
                    Text(portfolio.title + (portfolio.isVisibleToViewers ? "" : "（已隐藏）")).tag(Optional(portfolio.id))
                }
            }
            .pickerStyle(.menu)
            .tint(AppTheme.gold)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                if reduceMotion {
                    isCreatingPortfolio.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isCreatingPortfolio.toggle()
                    }
                }
            } label: {
                Label(
                    isCreatingPortfolio ? "收起新建相册" : "新建相册",
                    systemImage: isCreatingPortfolio ? "chevron.up" : "folder.badge.plus"
                )
                .adminSecondaryButton()
            }
            .disabled(isPublishing)

            if isCreatingPortfolio {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("相册名称，例如：宋韵", text: $newPortfolioTitle)
                    TextField("一句话介绍", text: $newPortfolioSubtitle)
                    TextField("英文眉题，例如：SONG AESTHETICS", text: $newPortfolioEyebrow)

                    Button { Task { await createPortfolio() } } label: {
                        Label("创建并发布相册", systemImage: "plus.circle.fill")
                            .adminPrimaryButton()
                    }
                    .disabled(
                        isPublishing ||
                        newPortfolioTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )

                    Text("创建后会立即出现在作品页，并自动切换到新相册，随后即可上传照片。")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                }
                .padding(14)
                .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
            }

            PhotosPicker(
                selection: $selectedPhotos,
                maxSelectionCount: 30,
                matching: .images
            ) {
                Label("批量上传照片到当前相册", systemImage: "photo.stack")
                    .adminPrimaryButton()
            }
            .disabled(isPublishing || selectedPortfolio == nil)

            if let portfolio = selectedPortfolio {
                Toggle(isOn: Binding(
                    get: { portfolio.isVisibleToViewers },
                    set: { visible in Task { await updateVisibility(portfolio, isVisible: visible) } }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("相册是否可见")
                        Text(portfolio.isVisibleToViewers
                            ? "用户可在作品页查看；关闭后隐藏，照片不会删除。"
                            : "已对用户隐藏；管理员仍可编辑，开启后恢复显示。")
                            .font(.caption)
                            .foregroundStyle(AppTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(AppTheme.gold)
                .disabled(isPublishing || !administratorEditorIsReady || portfolio.isVisible == nil)
                .accessibilityIdentifier("admin-portfolio-visibility")

                if portfolio.isVisible == nil {
                    Text("后台更新后可设置相册可见性，现有相册编辑不受影响。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 8)], spacing: 8) {
                    ForEach(Array(portfolio.images.enumerated()), id: \.element.id) { index, image in
                        ZStack {
                            AdminMediaPreview(url: image.url)
                                .frame(height: 126)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 4))

                            VStack {
                                HStack(alignment: .top) {
                                    if index == 0 {
                                        Label("封面", systemImage: "star.fill")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 5)
                                            .background(.black.opacity(0.68), in: Capsule())
                                            .foregroundStyle(MediaTheme.gold)
                                    }
                                    Spacer()
                                    Button { pendingRemoval = image } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.72))
                                            .font(.title3)
                                            .frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
                                    .accessibilityLabel("从作品集中移除照片")
                                }

                                Spacer()

                                HStack {
                                    PhotosPicker(
                                        selection: replacementSelection { item in
                                            Task { await replacePortfolioImage(item, image: image, in: portfolio) }
                                        },
                                        matching: .images
                                    ) {
                                        Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.72))
                                            .font(.title3)
                                            .frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
                                    .accessibilityLabel("替换这张照片")
                                    Spacer()
                                    Menu {
                                        Button {
                                            Task { await setAsCover(image, in: portfolio) }
                                        } label: {
                                            Label("设为封面", systemImage: "star")
                                        }
                                        .disabled(index == 0)

                                        Button {
                                            Task { await move(image, in: portfolio, by: -1) }
                                        } label: {
                                            Label("向前移动", systemImage: "arrow.left")
                                        }
                                        .disabled(index == 0)

                                        Button {
                                            Task { await move(image, in: portfolio, by: 1) }
                                        } label: {
                                            Label("向后移动", systemImage: "arrow.right")
                                        }
                                        .disabled(index == portfolio.images.count - 1)
                                    } label: {
                                        Image(systemName: "ellipsis.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.72))
                                            .font(.title3)
                                            .frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
                                    .accessibilityLabel("调整照片")
                                }
                            }
                            .padding(6)
                        }
                    }
                }
                Text("当前 \(portfolio.images.count) 张。第一张为封面；可单张替换、调整顺序，移出不会删除媒体库原文件。")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
            }
        }
        .textFieldStyle(AdminTextFieldStyle())
    }

    private var fanAccessEditor: some View {
        AdminSection(title: "注册审批", subtitle: "审核新用户，并按账号远程分配访问权限") {
            if pendingFanCount > 0 {
                Label("有 \(pendingFanCount) 个新用户等待审批", systemImage: "bell.badge.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.gold)
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.gold.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("admin-pending-fan-banner")
            }

            NavigationLink {
                FanAccessAdminView()
            } label: {
                Label("打开注册审批与权限管理", systemImage: "person.2.badge.gearshape")
                    .adminPrimaryButton()
            }
            .buttonStyle(.plain)

            Text("新注册账号默认不能进入 App；批准后才开放主页与内容。粉丝密码使用 WordPress 标准强哈希保存，管理端无法读取。")
                .font(.caption2)
                .lineSpacing(4)
                .foregroundStyle(AppTheme.muted)
        }
    }

    private var collaborationInboxEditor: some View {
        AdminSection(title: "合作邀约", subtitle: "查看服务器已收到的邀约，并记录处理进度") {
            if pendingCollaborationCount > 0 {
                Label(
                    "有 \(pendingCollaborationCount) 条新合作邀约等待处理",
                    systemImage: "envelope.badge.fill"
                )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.gold)
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.gold.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("admin-pending-collaboration-banner")
            }

            NavigationLink {
                CollaborationInboxView()
            } label: {
                HStack {
                    Label("打开合作邀约收件箱", systemImage: "tray.full")
                    Spacer()
                    if pendingCollaborationCount > 0 {
                        Text("\(pendingCollaborationCount)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.ink)
                            .accessibilityLabel("\(pendingCollaborationCount) 条待处理")
                    }
                }
                .adminPrimaryButton()
            }
            .buttonStyle(.plain)

            Text("邀约只有在服务器持久化成功后才会出现在这里；合作邮件的发送状态也会同步显示。")
                .font(.caption2)
                .lineSpacing(4)
                .foregroundStyle(AppTheme.muted)
        }
    }

    private func refreshPendingFanCount() async {
        guard admin.isAuthenticated,
              let directory = try? await admin.fetchFanDirectory() else { return }
        pendingFanCount = directory.users.filter {
            $0.status == FanAccountStatus.pending.rawValue
        }.count
    }

    private func refreshPendingCollaborationCount() async {
        guard admin.isAuthenticated else { return }
        guard let capabilities = try? await admin.fetchFeatureCapabilities(),
              capabilities.collaborationInboxEnabled else {
            collaborationInboxEnabled = false
            pendingCollaborationCount = 0
            return
        }
        collaborationInboxEnabled = true
        guard let directory = try? await admin.fetchCollaborationRequests(
                status: .received,
                perPage: 1
              ) else { return }
        pendingCollaborationCount = directory.total
    }

    private func refreshPendingCounts() async {
        await refreshPendingFanCount()
        await refreshPendingCollaborationCount()
    }

    private func monitorPendingCounts() async {
        guard admin.isAuthenticated else { return }
        while !Task.isCancelled, admin.isAuthenticated {
            await refreshPendingCounts()
            do {
                try await Task.sleep(for: .seconds(20))
            } catch {
                return
            }
        }
    }

    private var heroEditor: some View {
        AdminSection(title: "主页轮播", subtitle: "最多 5 张；可直接替换并调整显示顺序") {
            PhotosPicker(selection: $selectedHero, matching: .images) {
                Label("上传一张主页封面", systemImage: "photo.badge.plus")
                    .adminPrimaryButton()
            }
            .disabled(isPublishing || heroImageURLs.count >= 5)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 8)], spacing: 8) {
                ForEach(Array(heroImageURLs.enumerated()), id: \.offset) { index, url in
                    ZStack {
                        AdminMediaPreview(url: url)
                            .frame(height: 132)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        VStack {
                            HStack {
                                Text("第 \(index + 1) 张")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 5)
                                    .background(.black.opacity(0.68), in: Capsule())
                                Spacer()
                                if heroImageURLs.count > 1 {
                                    Button { heroImageURLs.remove(at: index) } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.72))
                                            .font(.title3)
                                            .frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
                                    .accessibilityLabel("移除主页封面")
                                }
                            }

                            Spacer()

                            HStack(spacing: 8) {
                                PhotosPicker(
                                    selection: replacementSelection { item in
                                        Task { await replaceHeroImage(item, at: index) }
                                    },
                                    matching: .images
                                ) {
                                    Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel("替换第 \(index + 1) 张主页封面")
                                Spacer()
                                Button { moveHero(at: index, by: -1) } label: {
                                    Image(systemName: "arrow.left.circle.fill")
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel("将第 \(index + 1) 张主页封面前移")
                                .disabled(index == 0)
                                Button { moveHero(at: index, by: 1) } label: {
                                    Image(systemName: "arrow.right.circle.fill")
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel("将第 \(index + 1) 张主页封面后移")
                                .disabled(index == heroImageURLs.count - 1)
                            }
                            .font(.title3)
                            .foregroundStyle(.white)
                        }
                        .padding(7)
                    }
                }
            }
            Text("替换会保留原来的轮播位置；全部修改需点击底部“保存并发布全部修改”。")
                .font(.caption2)
                .foregroundStyle(AppTheme.muted)
        }
    }

    private var aboutPortraitEditor: some View {
        AdminSection(title: "关于页人物图", subtitle: "替换后会同步到所有用户设备") {
            AdminMediaPreview(url: aboutPortraitURL)
            .frame(height: 300)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            PhotosPicker(selection: $selectedAboutPortrait, matching: .images) {
                Label("从手机相册替换人物图", systemImage: "person.crop.rectangle.badge.plus")
                    .adminPrimaryButton()
            }
            .disabled(isPublishing)

            Text("建议使用原始高清 2:3 竖版人像。照片仅从受信任的云端地址按需加载，不存入 App 本地。")
                .font(.caption2)
                .foregroundStyle(AppTheme.muted)
        }
    }

    private var launchPosterEditor: some View {
        AdminSection(title: "开屏海报", subtitle: "按日期自动投放；有效海报按稳定顺序轮换并避免连续重复") {
            PhotosPicker(selection: $selectedLaunchPoster, matching: .images) {
                Label("上传一张开屏海报", systemImage: "rectangle.portrait.badge.plus")
                    .adminPrimaryButton()
            }
            .disabled(isPublishing || launchPosterDrafts.count >= 12)

            ForEach(launchPosterDrafts) { poster in
                launchPosterCard(poster)
            }

            Text("上方按当前窗口比例预览开屏草稿，与实际开屏共用图片布局、字体和文案安全区；旋转设备可检查横竖屏。修改不会自动发布，请点击底部“保存并发布全部修改”。建议使用原始高清竖版照片。")
                .font(.caption2)
                .foregroundStyle(AppTheme.muted)
        }
        .textFieldStyle(AdminTextFieldStyle())
    }

    private func launchPosterCard(_ snapshot: LaunchPosterContent) -> some View {
        let poster = SafeIdentifiedBinding.element(for: snapshot, in: $launchPosterDrafts)

        return VStack(alignment: .leading, spacing: 13) {
            LaunchPosterAdminPreview(poster: poster.wrappedValue)
                .frame(height: 420)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 5))

            PhotosPicker(
                selection: replacementSelection { item in
                    Task { await replaceLaunchPoster(item, id: snapshot.id) }
                },
                matching: .images
            ) {
                Label("只替换这张海报图片", systemImage: "arrow.triangle.2.circlepath.camera")
                    .adminSecondaryButton()
            }
            .disabled(isPublishing)

            Toggle("启用这张海报", isOn: poster.isEnabled)
                .tint(AppTheme.gold)

            TextField("眉题（如东方美学）", text: poster.eyebrow)
            TextField("海报标题", text: poster.title)
            TextField("海报副标题", text: poster.subtitle)

            DatePicker(
                "开始日期",
                selection: poster.startsAt,
                displayedComponents: .date
            )
            DatePicker(
                "结束日期",
                selection: poster.endsAt,
                displayedComponents: .date
            )

            Stepper(value: poster.displaySeconds, in: 1.5...5, step: 0.5) {
                Text("展示 \(poster.wrappedValue.displaySeconds, specifier: "%.1f") 秒")
            }

            Button(role: .destructive) {
                launchPosterDrafts.removeAll { $0.id == snapshot.id }
            } label: {
                Label("移除这张海报", systemImage: "minus.circle")
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .font(.caption)
        }
        .padding(14)
        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
    }

    private var showreelEditor: some View {
        AdminSection(title: "Showreel", subtitle: "更换视频、海报和展示文案") {
            AdminMediaPreview(url: showreelDraft.posterURL)
                .frame(height: 190)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            TextField("栏目眉题", text: $showreelDraft.eyebrow)
            TextField("标题", text: $showreelDraft.title)
            TextField("一句话介绍", text: $showreelDraft.summary)
            TextField("时长，如 00:21", text: $showreelDraft.durationLabel)
            TextField("标签，用顿号分隔", text: $tagsText)

            HStack(spacing: 10) {
                Button { showVideoImporter = true } label: {
                    Label("上传视频", systemImage: "video.badge.plus")
                        .adminSecondaryButton()
                }
                PhotosPicker(selection: $selectedPoster, matching: .images) {
                    Label("更换海报", systemImage: "photo")
                        .adminSecondaryButton()
                }
            }
            .disabled(isPublishing)

            Text("视频上限 60 MB；支持系统可播放的 MP4/MOV。新文件上传后点击底部“保存并发布”。")
                .font(.caption2)
                .foregroundStyle(AppTheme.muted)
        }
        .textFieldStyle(AdminTextFieldStyle())
    }

    private var dramaEditor: some View {
        AdminSection(title: "影视履历", subtitle: "修改剧名、海报与公开跳转") {
            DisclosureGroup("统一更换红果入口") {
                Text("只替换与旧链接完全相同的入口，保留其他作品的专属链接。检查通过后更新草稿，仍需点击“保存并发布全部修改”。")
                    .font(.caption).foregroundStyle(AppTheme.muted)
                TextField("需要替换的旧链接", text: $sharedDramaOldURL)
                    .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                TextField("新的红果分享链接", text: $sharedDramaNewURL)
                    .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                Button(isCheckingDramaLink ? "正在检查…" : "检查并替换相同链接") {
                    Task { await replaceSharedDramaLink() }
                }
                .disabled(isPublishing || isCheckingDramaLink || !administratorEditorIsReady)
                if let dramaLinkCheckMessage {
                    Text(dramaLinkCheckMessage).font(.caption).accessibilityIdentifier("drama-link-check-result")
                }
            }
            ForEach(dramaDrafts) { drama in
                dramaCard(drama)
            }

            Button {
                dramaDrafts.append(DramaDraft())
            } label: {
                Label("添加一部短剧", systemImage: "plus")
                    .adminSecondaryButton()
            }
            .disabled(isPublishing || dramaDrafts.count >= 50)
        }
        .textFieldStyle(AdminTextFieldStyle())
    }

    @MainActor
    private func replaceSharedDramaLink() async {
        guard administratorEditorIsReady, !isPublishing, !isCheckingDramaLink else { return }
        guard let old = URL(string: sharedDramaOldURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let new = URL(string: sharedDramaNewURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              DramaLinkPolicy.isHongguo(old), DramaLinkPolicy.isHongguo(new), old != new else {
            dramaLinkCheckMessage = "请填写两个不同的红果 HTTPS 链接。"; return
        }
        let contentID = administratorContentLoadID
        let original = dramaDrafts
        guard let works = try? original.map({ try $0.value() }),
              works.contains(where: { $0.destinationURL == old }) else {
            dramaLinkCheckMessage = "没有匹配的入口，或现有短剧资料尚未填写完整。"; return
        }
        isCheckingDramaLink = true
        defer { isCheckingDramaLink = false }
        let health = await DramaLinkChecker.check(new, requireActor: true)
        guard !Task.isCancelled, administratorEditorIsReady,
              administratorContentLoadID == contentID, !isPublishing, dramaDrafts == original,
              sharedDramaOldURL.trimmingCharacters(in: .whitespacesAndNewlines) == old.absoluteString,
              sharedDramaNewURL.trimmingCharacters(in: .whitespacesAndNewlines) == new.absoluteString else {
            dramaLinkCheckMessage = "资料已变化，请重新检查后再替换。"; return
        }
        guard health == .available else { dramaLinkCheckMessage = health.message; return }
        dramaDrafts = DramaLinkPolicy.replacing(works, from: old, to: new).map(DramaDraft.init)
        sharedDramaOldURL = new.absoluteString
        dramaLinkCheckMessage = "已更新 \(works.filter { $0.destinationURL == old }.count) 个草稿入口，请保存并发布。"
    }

    private func dramaCard(_ snapshot: DramaDraft) -> some View {
        let drama = SafeIdentifiedBinding.element(for: snapshot, in: $dramaDrafts)

        return VStack(alignment: .leading, spacing: 10) {
            if let url = URL(string: drama.wrappedValue.imageURL),
               ContentSecurityPolicy.isTrustedMediaURL(url, environment: admin.serviceEnvironment) {
                AdminMediaPreview(url: url)
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            PhotosPicker(
                selection: replacementSelection { item in
                    Task { await replaceDramaPoster(item, id: snapshot.id) }
                },
                matching: .images
            ) {
                Label("从手机相册替换海报", systemImage: "photo.badge.plus")
                    .adminSecondaryButton()
            }
            .disabled(isPublishing)
            TextField("剧名", text: drama.title)
            TextField("海报 HTTPS 地址（高级）", text: drama.imageURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            TextField("观看页 HTTPS 地址", text: drama.destinationURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button(role: .destructive) {
                dramaDrafts.removeAll { $0.id == snapshot.id }
            } label: {
                Label("移除这部作品", systemImage: "minus.circle")
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .font(.caption)
        }
        .padding(14)
        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
    }

    private var publishControls: some View {
        VStack(spacing: 12) {
            Button { Task { await publishContent() } } label: {
                Label("保存并发布全部修改", systemImage: "icloud.and.arrow.up")
                    .adminPrimaryButton()
            }
            .disabled(isPublishing || isCheckingDramaLink || !administratorEditorIsReady)

            Button("放弃未发布的文字修改") { loadDrafts() }
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
                .frame(minHeight: 44)
                .disabled(isPublishing || !administratorEditorIsReady)
        }
    }

    private var editablePortfolios: [Portfolio] {
        store.managedPortfolios.isEmpty ? store.portfolios : store.managedPortfolios
    }

    private var selectedPortfolioBinding: Binding<Int?> {
        Binding(
            get: { selectedPortfolioID ?? editablePortfolios.first?.id },
            set: { selectedPortfolioID = $0 }
        )
    }

    private var selectedPortfolio: Portfolio? {
        let id = selectedPortfolioID ?? editablePortfolios.first?.id
        return editablePortfolios.first { $0.id == id }
    }

    private func loadAdministratorContent() async {
        guard admin.isAuthenticated else {
            invalidateAdministratorContentLoad()
            return
        }

        let loadID = UUID()
        administratorContentLoadID = loadID
        hasLoadedAdministratorContent = false
        isLoadingAdministratorContent = true
        administratorContentError = nil
        resetAdministratorDrafts()
        defer {
            if administratorContentLoadID == loadID {
                isLoadingAdministratorContent = false
            }
        }

        do {
            let manifest = try await admin.fetchContent()
            guard administratorContentLoadID == loadID,
                  admin.isAuthenticated else { return }
            guard AdminContentEditingPolicy.isFullAdministratorManifest(manifest) else {
                throw AdminAPIError.invalidResponse
            }
            store.applyPublishedManifest(manifest)
            loadDrafts()
            hasLoadedAdministratorContent = true
        } catch {
            guard administratorContentLoadID == loadID,
                  admin.isAuthenticated else { return }
            hasLoadedAdministratorContent = false
            administratorContentError = (error as? LocalizedError)?.errorDescription
                ?? "无法安全载入管理员完整内容，请稍后重试。"
        }
    }

    private func invalidateAdministratorContentLoad() {
        administratorContentLoadID = UUID()
        hasLoadedAdministratorContent = false
        isLoadingAdministratorContent = false
        administratorContentError = nil
        activeOperationID = nil
        isPublishing = false
        operationMessage = nil
        operationFailed = false
        resetAdministratorDrafts()
    }

    private func resetAdministratorDrafts() {
        heroImageURLs = []
        aboutPortraitURL = nil
        launchPosterDrafts = []
        showreelDraft = ContentCatalog.showreel
        tagsText = ContentCatalog.showreel.tags.joined(separator: "、")
        dramaDrafts = []
        selectedPortfolioID = nil
        isCreatingPortfolio = false
        selectedPhotos = []
        selectedHero = nil
        selectedLaunchPoster = nil
        selectedAboutPortrait = nil
        selectedPoster = nil
        pendingRemoval = nil
    }

    private func loadDrafts() {
        heroImageURLs = store.heroImages
        aboutPortraitURL = store.configuredAboutPortraitURL
        launchPosterDrafts = store.launchPosters
        if let showreel = store.showreel {
            showreelDraft = showreel
            tagsText = showreel.tags.joined(separator: "、")
        }
        dramaDrafts = store.dramas.map(DramaDraft.init)
        let groups = Dictionary(grouping: store.dramas.filter { DramaLinkPolicy.isHongguo($0.destinationURL) }, by: \.destinationURL)
        sharedDramaOldURL = groups.sorted {
            $0.value.count == $1.value.count ? $0.key.absoluteString < $1.key.absoluteString : $0.value.count > $1.value.count
        }.first?.key.absoluteString ?? ContentCatalog.hongguoURL.absoluteString
        sharedDramaNewURL = ""
        dramaLinkCheckMessage = nil
        if selectedPortfolioID.flatMap({ selectedID in
            editablePortfolios.first(where: { $0.id == selectedID })
        }) == nil {
            selectedPortfolioID = editablePortfolios.first?.id
        }
    }

    private func uploadPortfolioPhotos(_ items: [PhotosPickerItem]) async {
        guard let portfolio = selectedPortfolio, !items.isEmpty else { return }
        await performOperation(success: "\(items.count) 张照片已发布到「\(portfolio.title)」") { contentLoadID in
            var ids = portfolio.images.map(\.id)
            for item in items {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw AdminAPIError.invalidResponse
                }
                try ensureAdministratorOperationIsCurrent(contentLoadID)
                let type = preferredType(for: item)
                let media = try await admin.upload(
                    data: data,
                    filename: generatedFilename(prefix: "portfolio", type: type),
                    mimeType: type.preferredMIMEType ?? "image/jpeg"
                )
                try ensureAdministratorOperationIsCurrent(contentLoadID)
                ids.append(media.id)
            }
            let manifest = try await admin.updateGallery(portfolioID: portfolio.id, mediaIDs: ids)
            try applyAdministratorManifest(manifest, contentLoadID: contentLoadID)
        }
        selectedPhotos = []
    }

    private func updateVisibility(_ portfolio: Portfolio, isVisible: Bool) async {
        guard !isPublishing, isVisible != portfolio.isVisibleToViewers else { return }
        await performOperation(success: isVisible ? "相册已恢复显示" : "相册已隐藏，照片仍保留") { contentLoadID in
            let manifest = try await admin.updatePortfolioVisibility(portfolio, isVisible: isVisible)
            try ensureAdministratorOperationIsCurrent(contentLoadID)
            store.applyPublishedManifest(manifest)
        }
    }

    private func createPortfolio() async {
        let title = newPortfolioTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = newPortfolioSubtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let eyebrow = newPortfolioEyebrow.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }

        await performOperation(success: "相册「\(title)」已创建并发布") { contentLoadID in
            let result = try await admin.createPortfolio(
                title: title,
                subtitle: subtitle.isEmpty ? "易姝影像作品" : subtitle,
                eyebrow: eyebrow.isEmpty ? "PORTFOLIO" : eyebrow
            )
            try applyAdministratorManifest(result.content, contentLoadID: contentLoadID)
            selectedPortfolioID = result.portfolioID
            newPortfolioTitle = ""
            newPortfolioSubtitle = "易姝影像作品"
            newPortfolioEyebrow = "PORTFOLIO"
            isCreatingPortfolio = false
        }
    }

    private func uploadHeroImage(_ item: PhotosPickerItem) async {
        await performOperation(success: "主页封面已上传，等待发布") { contentLoadID in
            let media = try await uploadImage(item, prefix: "hero")
            try ensureAdministratorOperationIsCurrent(contentLoadID)
            heroImageURLs.append(media.sourceURL)
        }
        selectedHero = nil
    }

    private func replaceHeroImage(_ item: PhotosPickerItem, at index: Int) async {
        await performOperation(success: "主页第 \(index + 1) 张封面已替换，等待发布") { contentLoadID in
            let media = try await uploadImage(item, prefix: "hero-replacement")
            try ensureAdministratorOperationIsCurrent(contentLoadID)
            guard heroImageURLs.indices.contains(index) else { throw AdminAPIError.invalidResponse }
            heroImageURLs[index] = media.sourceURL
        }
    }

    private func moveHero(at index: Int, by offset: Int) {
        let target = index + offset
        guard heroImageURLs.indices.contains(index), heroImageURLs.indices.contains(target) else { return }
        heroImageURLs.swapAt(index, target)
    }

    private func uploadAboutPortrait(_ item: PhotosPickerItem) async {
        await performOperation(success: "关于页人物图已替换并发布") { contentLoadID in
            let media = try await uploadImage(item, prefix: "about-portrait")
            try ensureAdministratorOperationIsCurrent(contentLoadID)
            let manifest = try await admin.publishAboutPortrait(media.sourceURL)
            try applyAdministratorManifest(manifest, contentLoadID: contentLoadID)
            aboutPortraitURL = manifest.aboutPortraitURL
        }
        selectedAboutPortrait = nil
    }

    private func uploadLaunchPoster(_ item: PhotosPickerItem) async {
        await performOperation(success: "开屏海报已上传，设置日期后等待发布") { contentLoadID in
            let media = try await uploadImage(item, prefix: "launch-poster")
            try ensureAdministratorOperationIsCurrent(contentLoadID)
            launchPosterDrafts.append(.newDraft(imageURL: media.sourceURL))
        }
        selectedLaunchPoster = nil
    }

    private func replaceLaunchPoster(_ item: PhotosPickerItem, id: String) async {
        await performOperation(success: "图片已替换到草稿，保存并发布后生效；原文案和日期不变") { contentLoadID in
            let media = try await uploadImage(item, prefix: "launch-poster-replacement")
            try ensureAdministratorOperationIsCurrent(contentLoadID)
            guard let index = launchPosterDrafts.firstIndex(where: { $0.id == id }) else {
                throw AdminAPIError.invalidResponse
            }
            launchPosterDrafts[index].imageURL = media.sourceURL
        }
    }

    private func replacePortfolioImage(
        _ item: PhotosPickerItem,
        image: PortfolioImage,
        in portfolio: Portfolio
    ) async {
        await performOperation(success: "「\(portfolio.title)」中的照片已原位替换") { contentLoadID in
            let media = try await uploadImage(item, prefix: "portfolio-replacement")
            try ensureAdministratorOperationIsCurrent(contentLoadID)
            var ids = portfolio.images.map(\.id)
            guard let index = ids.firstIndex(of: image.id) else { throw AdminAPIError.invalidResponse }
            ids[index] = media.id
            let manifest = try await admin.updateGallery(portfolioID: portfolio.id, mediaIDs: ids)
            try applyAdministratorManifest(manifest, contentLoadID: contentLoadID)
        }
    }

    private func remove(_ image: PortfolioImage) async {
        guard let portfolio = selectedPortfolio else { return }
        pendingRemoval = nil
        await performOperation(success: "照片已移出「\(portfolio.title)」") { contentLoadID in
            let ids = portfolio.images.map(\.id).filter { $0 != image.id }
            let manifest = try await admin.updateGallery(portfolioID: portfolio.id, mediaIDs: ids)
            try applyAdministratorManifest(manifest, contentLoadID: contentLoadID)
        }
    }

    private func setAsCover(_ image: PortfolioImage, in portfolio: Portfolio) async {
        guard portfolio.images.first?.id != image.id else { return }
        await performOperation(success: "「\(portfolio.title)」封面已更新") { contentLoadID in
            let ids = [image.id] + portfolio.images.map(\.id).filter { $0 != image.id }
            let manifest = try await admin.updateGallery(portfolioID: portfolio.id, mediaIDs: ids)
            try applyAdministratorManifest(manifest, contentLoadID: contentLoadID)
        }
    }

    private func move(_ image: PortfolioImage, in portfolio: Portfolio, by offset: Int) async {
        var ids = portfolio.images.map(\.id)
        guard let currentIndex = ids.firstIndex(of: image.id) else { return }
        let targetIndex = currentIndex + offset
        guard ids.indices.contains(targetIndex) else { return }
        ids.swapAt(currentIndex, targetIndex)

        await performOperation(success: "「\(portfolio.title)」照片顺序已更新") { contentLoadID in
            let manifest = try await admin.updateGallery(portfolioID: portfolio.id, mediaIDs: ids)
            try applyAdministratorManifest(manifest, contentLoadID: contentLoadID)
        }
    }

    private func uploadShowreelPoster(_ item: PhotosPickerItem) async {
        await performOperation(success: "新海报已上传，等待发布") { contentLoadID in
            let media = try await uploadImage(item, prefix: "showreel-poster")
            try ensureAdministratorOperationIsCurrent(contentLoadID)
            showreelDraft.posterURL = media.sourceURL
        }
        selectedPoster = nil
    }

    private func replaceDramaPoster(_ item: PhotosPickerItem, id: String) async {
        await performOperation(success: "影视海报已替换，等待发布") { contentLoadID in
            let media = try await uploadImage(item, prefix: "drama-poster")
            try ensureAdministratorOperationIsCurrent(contentLoadID)
            guard let index = dramaDrafts.firstIndex(where: { $0.id == id }) else {
                throw AdminAPIError.invalidResponse
            }
            dramaDrafts[index].imageURL = media.sourceURL.absoluteString
        }
    }

    private func uploadShowreelVideo(_ url: URL) async {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        await performOperation(success: "新视频已上传，等待发布") { contentLoadID in
            let type = UTType(filenameExtension: url.pathExtension) ?? .mpeg4Movie
            let media = try await admin.upload(
                fileURL: url,
                filename: generatedFilename(prefix: "showreel", type: type),
                mimeType: type.preferredMIMEType ?? "video/mp4"
            )
            try ensureAdministratorOperationIsCurrent(contentLoadID)
            showreelDraft.videoURL = media.sourceURL
        }
    }

    private func publishContent() async {
        guard launchPosterDrafts.allSatisfy({
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.startsAt < $0.endsAt
                && (1.5...5).contains($0.displaySeconds)
        }) else {
            operationMessage = "请检查开屏海报标题、日期范围和展示时长。"
            operationFailed = true
            return
        }

        let requiredShowreelText = [
            showreelDraft.eyebrow,
            showreelDraft.title,
            showreelDraft.summary,
            showreelDraft.durationLabel,
        ]
        guard requiredShowreelText.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            operationMessage = "请完整填写 Showreel 的眉题、标题、介绍和时长。"
            operationFailed = true
            return
        }

        let dramas: [DramaWork]
        do {
            dramas = try dramaDrafts.map { try $0.value() }
        } catch {
            operationMessage = error.localizedDescription
            operationFailed = true
            return
        }
        showreelDraft.tags = tagsText
            .components(separatedBy: CharacterSet(charactersIn: "、,，"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        await performOperation(success: "内容已发布，普通用户下次刷新即可看到") { contentLoadID in
            let manifest = try await admin.publish(
                heroImages: heroImageURLs,
                aboutPortraitURL: aboutPortraitURL,
                launchPosters: launchPosterDrafts,
                showreel: showreelDraft,
                dramas: dramas
            )
            try applyAdministratorManifest(manifest, contentLoadID: contentLoadID)
        }
    }

    private func performOperation(
        success: String,
        operation: (UUID) async throws -> Void
    ) async {
        guard administratorEditorIsReady else {
            operationFailed = true
            operationMessage = "管理员完整内容尚未安全载入，请重新载入后再试。"
            return
        }
        let contentLoadID = administratorContentLoadID
        let operationID = UUID()
        activeOperationID = operationID
        isPublishing = true
        operationMessage = nil
        operationFailed = false
        defer {
            if activeOperationID == operationID {
                activeOperationID = nil
                isPublishing = false
            }
        }
        do {
            try ensureAdministratorOperationIsCurrent(contentLoadID)
            try await operation(contentLoadID)
            try ensureAdministratorOperationIsCurrent(contentLoadID)
            guard activeOperationID == operationID else { return }
            operationMessage = success
        } catch {
            guard activeOperationID == operationID,
                  administratorContentLoadID == contentLoadID else { return }
            operationFailed = true
            operationMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func ensureAdministratorOperationIsCurrent(_ contentLoadID: UUID) throws {
        guard administratorContentLoadID == contentLoadID,
              administratorEditorIsReady else {
            throw AdminAPIError.invalidCredentials
        }
    }

    private func applyAdministratorManifest(
        _ manifest: AppContentManifest,
        contentLoadID: UUID
    ) throws {
        try ensureAdministratorOperationIsCurrent(contentLoadID)
        guard AdminContentEditingPolicy.isFullAdministratorManifest(manifest) else {
            throw AdminAPIError.invalidResponse
        }
        store.applyPublishedManifest(manifest)
    }

    private func uploadImage(_ item: PhotosPickerItem, prefix: String) async throws -> UploadedMedia {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw AdminAPIError.invalidResponse
        }
        let type = preferredType(for: item)
        return try await admin.upload(
            data: data,
            filename: generatedFilename(prefix: prefix, type: type),
            mimeType: type.preferredMIMEType ?? "image/jpeg"
        )
    }

    private func replacementSelection(
        _ action: @escaping (PhotosPickerItem) -> Void
    ) -> Binding<PhotosPickerItem?> {
        Binding(
            get: { nil },
            set: { item in
                if let item { action(item) }
            }
        )
    }

    private func preferredType(for item: PhotosPickerItem) -> UTType {
        item.supportedContentTypes.first { $0.preferredMIMEType != nil && $0.preferredFilenameExtension != nil }
            ?? .jpeg
    }

    private func generatedFilename(prefix: String, type: UTType) -> String {
        let stamp = Int(Date().timeIntervalSince1970)
        let suffix = UUID().uuidString.lowercased().prefix(8)
        return "\(prefix)-\(stamp)-\(suffix).\(type.preferredFilenameExtension ?? "bin")"
    }
}

private struct CollaborationInboxView: View {
    @EnvironmentObject private var admin: AdminSessionStore
    @State private var directory: AdminCollaborationDirectory?
    @State private var isLoading = false
    @State private var updatingRequestIDs = Set<String>()
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    header

                    if isLoading, directory == nil {
                        HStack(spacing: 12) {
                            ProgressView().tint(AppTheme.gold)
                            Text("正在读取合作邀约")
                        }
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.muted)
                    } else if let directory, directory.requests.isEmpty {
                        ContentUnavailableView(
                            "暂无合作邀约",
                            systemImage: "tray",
                            description: Text("新邀约经服务器确认保存后会显示在这里。")
                        )
                        .foregroundStyle(AppTheme.muted)
                    } else if let directory {
                        ForEach(directory.requests) { request in
                            requestCard(request)
                        }
                        if directory.total > directory.requests.count {
                            Text("当前显示最新 \(directory.requests.count) 条，共 \(directory.total) 条。")
                                .font(.caption)
                                .foregroundStyle(AppTheme.muted)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 60)
                .frame(maxWidth: 840, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .refreshable { await load() }
        }
        .navigationTitle("合作邀约")
        .navigationBarTitleDisplayMode(.inline)
        .themeNavigationChrome()
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("COLLABORATION INBOX")
                .font(.caption2.weight(.semibold))
                .tracking(3)
                .foregroundStyle(AppTheme.gold)
            Text("合作邀约收件箱")
                .font(.system(.largeTitle, design: .serif))
                .accessibilityAddTraits(.isHeader)
            if let directory {
                Text("共 \(directory.total) 条 · 待处理 \(pendingCount(in: directory)) 条")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.muted)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(AppTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
                Button {
                    Task { await load() }
                } label: {
                    Label("重新读取", systemImage: "arrow.clockwise")
                        .adminSecondaryButton()
                }
                .disabled(isLoading)
            }
        }
    }

    private func requestCard(_ request: AdminCollaborationRequest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(request.contactName)
                        .font(.title3.weight(.semibold))
                    Text(projectTypeTitle(request.projectType))
                        .font(.caption)
                        .foregroundStyle(AppTheme.gold)
                }
                Spacer()
                Menu {
                    ForEach(CollaborationRequestStatus.allCases) { status in
                        Button(status.title) {
                            Task { await update(request, to: status) }
                        }
                        .disabled(status == request.requestStatus)
                    }
                } label: {
                    HStack(spacing: 6) {
                        if updatingRequestIDs.contains(request.requestID) {
                            ProgressView().tint(AppTheme.gold)
                        }
                        Text(request.requestStatus?.title ?? "未知状态")
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.warmWhite)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .disabled(updatingRequestIDs.contains(request.requestID))
                .accessibilityLabel("处理状态：\(request.requestStatus?.title ?? "未知")")
            }

            Divider().overlay(AppTheme.line)

            detailRow("联系方式", value: request.contactMethod)
            if !request.organization.isEmpty {
                detailRow("公司 / 项目", value: request.organization)
            }
            if !request.city.isEmpty {
                detailRow("拍摄城市", value: request.city)
            }
            if !request.preferredDate.isEmpty {
                detailRow("意向日期", value: request.preferredDate)
            }
            if !request.budget.isEmpty {
                detailRow("预算范围", value: request.budget)
            }
            if !request.details.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("项目说明")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                    Text(request.details)
                        .font(.body)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider().overlay(AppTheme.line)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(mailDeliveryTitle(request.delivery), systemImage: mailDeliveryIcon(request.delivery))
                    .foregroundStyle(mailDeliveryColor(request.delivery))
                Spacer()
                Text(request.receivedAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(AppTheme.muted)
            }
            .font(.caption2)

            Text("请求编号 \(request.requestID)")
                .font(.caption2.monospaced())
                .foregroundStyle(AppTheme.muted)
                .textSelection(.enabled)
        }
        .padding(16)
        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 8))
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(AppTheme.muted)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func load() async {
        guard admin.isAuthenticated, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            directory = try await admin.fetchCollaborationRequests(perPage: 100)
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "无法读取合作邀约。"
        }
    }

    private func update(
        _ request: AdminCollaborationRequest,
        to status: CollaborationRequestStatus
    ) async {
        guard admin.isAuthenticated,
              request.requestStatus != status,
              !updatingRequestIDs.contains(request.requestID) else { return }
        updatingRequestIDs.insert(request.requestID)
        defer { updatingRequestIDs.remove(request.requestID) }
        do {
            let updated = try await admin.updateCollaborationRequest(request, status: status)
            guard var current = directory,
                  let index = current.requests.firstIndex(where: {
                      $0.requestID == updated.requestID
                  }) else {
                await load()
                return
            }
            var requests = current.requests
            requests[index] = updated
            current = AdminCollaborationDirectory(
                requests: requests,
                page: current.page,
                perPage: current.perPage,
                total: current.total,
                statuses: current.statuses
            )
            directory = current
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "无法更新合作邀约。"
        }
    }

    private func pendingCount(in directory: AdminCollaborationDirectory) -> Int {
        directory.requests.filter { $0.requestStatus == .received }.count
    }

    private func projectTypeTitle(_ rawValue: String) -> String {
        switch rawValue {
        case "drama": "短剧 / 影视出演"
        case "commercial": "商业拍摄"
        case "brand": "品牌合作"
        case "modeling": "平面 / 模特"
        case "event": "活动出席"
        default: "其他合作"
        }
    }

    private func mailDeliveryTitle(_ delivery: AdminCollaborationDelivery) -> String {
        switch delivery.status {
        case "sent": "邮件服务已接受"
        case "dead": "邮件多次重试失败"
        case "processing": "正在交给邮件服务"
        default: "等待交给邮件服务"
        }
    }

    private func mailDeliveryIcon(_ delivery: AdminCollaborationDelivery) -> String {
        switch delivery.status {
        case "sent": "envelope.badge.fill"
        case "dead": "exclamationmark.triangle.fill"
        case "processing": "arrow.triangle.2.circlepath"
        default: "clock"
        }
    }

    private func mailDeliveryColor(_ delivery: AdminCollaborationDelivery) -> Color {
        delivery.status == "dead" ? AppTheme.warning : AppTheme.gold
    }
}

struct LaunchPosterPreviewLayout {
    let scale: CGFloat
    let size: CGSize

    init(viewport: CGSize, available: CGSize) {
        guard viewport.width.isFinite, viewport.height.isFinite,
              available.width.isFinite, available.height.isFinite,
              viewport.width > 0, viewport.height > 0,
              available.width > 0, available.height > 0 else {
            scale = 0
            size = .zero
            return
        }
        scale = min(available.width / viewport.width, available.height / viewport.height, 1)
        size = CGSize(width: viewport.width * scale, height: viewport.height * scale)
    }
}

struct LaunchPosterAdminPreview: View {
    let poster: LaunchPosterContent
    @State private var artworkIsVisible = false

    var body: some View {
        GeometryReader { proxy in
            let viewport = LaunchPosterWindowSafeArea.windowSize ?? proxy.size
            let layout = LaunchPosterPreviewLayout(viewport: viewport, available: proxy.size)

            ZStack {
                AppTheme.elevatedInk

                // Scale a real window-sized canvas, not a separately restyled
                // card. No launch timer or tappable skip control runs here.
                LaunchPosterCanvas(
                    poster: poster,
                    size: viewport,
                    safeAreaInsets: LaunchPosterWindowSafeArea.resolvedInsets(),
                    artworkIsVisible: $artworkIsVisible,
                    dismiss: {},
                    imageTargetSize: layout.size,
                    isPreview: true
                )
                .frame(width: viewport.width, height: viewport.height)
                .scaleEffect(layout.scale)
                .frame(width: layout.size.width, height: layout.size.height)
                .clipped()
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                // Cropped image descendants retain their uncropped AX bounds.
                // Expose the bounded preview rectangle instead of those pixels.
                Color.clear
                    .frame(width: layout.size.width, height: layout.size.height)
                    .contentShape(Rectangle())
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("开屏草稿预览")
                    .accessibilityValue("\(poster.eyebrow)，\(poster.title)，\(poster.subtitle)")
                    .accessibilityIdentifier("admin-launch-poster-preview")
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

#if DEBUG
/// An isolated preview fixture: no administrator session or publishing API.
struct LaunchPosterAdminPreviewFixture: View {
    @State private var poster = LaunchPosterContent.newDraft(
        imageURL: ContentCatalog.launchPosters[0].imageURL
    )

    var body: some View {
        VStack(spacing: 16) {
            LaunchPosterAdminPreview(poster: poster)
                .frame(maxHeight: 420)
            Button("修改测试草稿") {
                poster.eyebrow = "测试眉题"
                poster.title = "新的测试标题"
                poster.subtitle = "这是一条未发布的测试文案"
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.gold)
            .foregroundStyle(AppTheme.ink)
            .frame(minHeight: 44)
            .accessibilityIdentifier("admin-launch-preview-update-draft")
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.ink)
    }
}
#endif

/// A neutral, aspect-preserving surface used exclusively by administrator
/// editing screens. Centralizing this prevents fixed-height grids from silently
/// falling back to `ArtworkImage`'s presentation-oriented `.fill` default.
private struct AdminMediaPreview: View {
    let url: URL?

    var body: some View {
        ZStack {
            AppTheme.elevatedInk

            if let url {
                ArtworkImage(
                    url: url,
                    contentMode: AdminMediaPreviewPolicy.contentMode
                )
            } else {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(AppTheme.muted)
            }
        }
        .clipped()
    }
}

private struct DramaDraft: Identifiable, Equatable {
    var id: String
    var title: String
    var imageURL: String
    var destinationURL: String

    init(_ drama: DramaWork) {
        id = drama.id
        title = drama.title
        imageURL = drama.imageURL.absoluteString
        destinationURL = drama.destinationURL.absoluteString
    }

    init() {
        id = UUID().uuidString.lowercased()
        title = ""
        imageURL = "https://"
        destinationURL = "https://"
    }

    func value() throws -> DramaWork {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let image = URL(string: imageURL), image.scheme == "https",
              let destination = URL(string: destinationURL), destination.scheme == "https" else {
            throw AdminAPIError.server("请完整填写每部短剧的标题和 HTTPS 地址。")
        }
        return DramaWork(id: id, title: title, imageURL: image, destinationURL: destination)
    }
}

private struct AdminSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.title2, design: .serif))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.caption).foregroundStyle(AppTheme.muted)
            }
            content
        }
    }
}

private struct AdminTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 13)
            .frame(minHeight: 48)
            .modifier(ThemeInputChrome())
    }
}

private extension View {
    nonisolated func adminPrimaryButton() -> some View { modifier(AdminPrimaryButtonChrome()) }
    nonisolated func adminSecondaryButton() -> some View { modifier(AdminSecondaryButtonChrome()) }
}

private struct AdminPrimaryButtonChrome: ViewModifier {
    nonisolated init() {}
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(AppTheme.warmWhite, in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(AppTheme.ink)
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 48)
    }

}

private struct AdminSecondaryButtonChrome: ViewModifier {
    nonisolated init() {}
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(AppTheme.warmWhite)
            .font(.subheadline.weight(.medium))
            .frame(minHeight: 44)
    }
}
