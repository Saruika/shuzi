import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Owns the complete administrator navigation scope. Present this view as a
/// full-screen cover so child approval screens stay inside the same scope and
/// dismissing the cover can reliably lock credentials and protected content.
struct AdminAccessView: View {
    @EnvironmentObject private var admin: AdminSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var hasLockedOnEntry = false

    var body: some View {
        Group {
            if hasLockedOnEntry {
                NavigationStack {
                    AdminView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("关闭") { dismiss() }
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
        manifest.showreel != nil
            && manifest.portfolios.allSatisfy {
                $0.images.count == $0.displayImageCount
            }
    }
}

struct AdminView: View {
    @EnvironmentObject private var admin: AdminSessionStore
    @EnvironmentObject private var store: PortfolioStore
    @State private var username = "yishu_app_manager"
    @State private var applicationPassword = ""
    @State private var heroImageURLs = ContentCatalog.heroImages
    @State private var aboutPortraitURL = ContentCatalog.aboutPortraitURL
    @State private var launchPosterDrafts = ContentCatalog.launchPosters
    @State private var showreelDraft = ContentCatalog.showreel
    @State private var dramaDrafts: [DramaDraft] = ContentCatalog.dramas.map(DramaDraft.init)
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
    @State private var hasLoadedAdministratorContent = false
    @State private var isLoadingAdministratorContent = false
    @State private var administratorContentError: String?
    @State private var administratorContentLoadID = UUID()
    @State private var activeOperationID: UUID?

    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            ScrollView {
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
            .scrollIndicators(.hidden)
        }
        .navigationTitle(admin.isAuthenticated ? "内容管理" : "管理员登录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(AppTheme.ink, for: .navigationBar)
        .task(id: admin.isAuthenticated) {
            if admin.isAuthenticated {
                await loadAdministratorContent()
            } else {
                invalidateAdministratorContentLoad()
            }
        }
        .task(id: admin.isAuthenticated) {
            await monitorPendingFanCount()
        }
        .onChange(of: admin.isAuthenticated) { _, authenticated in
            if authenticated {
                applicationPassword = ""
                Task { await refreshPendingFanCount() }
            } else {
                invalidateAdministratorContentLoad()
                pendingFanCount = 0
            }
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
                .font(.system(size: 10, weight: .semibold))
                .tracking(3)
                .foregroundStyle(AppTheme.gold)
            Text("正在核对完整内容")
                .font(.editorial(34))
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
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
        }
        .padding(22)
        .padding(.top, 24)
    }

    private var login: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 10) {
                Text("ADMIN ACCESS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(3)
                    .foregroundStyle(AppTheme.gold)
                Text("管理员登录")
                    .font(.editorial(40))
                    .accessibilityIdentifier("admin-login-heading")
                Text("普通用户需先注册并通过审批。这里用于注册审批、权限分配和内容发布。")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.muted)
            }

            VStack(spacing: 14) {
                TextField("管理员账号", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("管理员访问码", text: $applicationPassword)
                    .textContentType(.password)
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
                    .foregroundStyle(.orange)
            }

            Label("访问码只保存在本设备 Keychain，可随时在服务器单独吊销。", systemImage: "lock.shield")
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
                .font(.system(size: 10, weight: .semibold))
                .tracking(3)
                .foregroundStyle(AppTheme.gold)
            Text("内容工作台")
                .font(.editorial(38))
            HStack {
                Label("管理员模式", systemImage: "checkmark.shield")
                Spacer()
                Button("退出") { admin.signOut() }
                    .disabled(isPublishing)
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
                    .foregroundStyle(operationFailed ? .orange : AppTheme.gold)
            }
        }
    }

    private var portfolioEditor: some View {
        AdminSection(title: "照片作品", subtitle: "新建相册、上传照片与调整内容") {
            Picker("当前相册", selection: selectedPortfolioBinding) {
                ForEach(store.portfolios) { portfolio in
                    Text(portfolio.title).tag(Optional(portfolio.id))
                }
            }
            .pickerStyle(.menu)
            .tint(AppTheme.gold)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCreatingPortfolio.toggle()
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                    ForEach(Array(portfolio.images.enumerated()), id: \.element.id) { index, image in
                        ZStack {
                            ArtworkImage(url: image.url)
                                .frame(height: 126)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 4))

                            VStack {
                                HStack(alignment: .top) {
                                    if index == 0 {
                                        Label("封面", systemImage: "star.fill")
                                            .font(.system(size: 9, weight: .semibold))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 5)
                                            .background(.black.opacity(0.68), in: Capsule())
                                            .foregroundStyle(AppTheme.gold)
                                    }
                                    Spacer()
                                    Button { pendingRemoval = image } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.72))
                                            .font(.title3)
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

    private func refreshPendingFanCount() async {
        guard admin.isAuthenticated,
              let directory = try? await admin.fetchFanDirectory() else { return }
        pendingFanCount = directory.users.filter {
            $0.status == FanAccountStatus.pending.rawValue
        }.count
    }

    private func monitorPendingFanCount() async {
        guard admin.isAuthenticated else { return }
        while !Task.isCancelled, admin.isAuthenticated {
            await refreshPendingFanCount()
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

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(Array(heroImageURLs.enumerated()), id: \.offset) { index, url in
                    ZStack {
                        ArtworkImage(url: url)
                            .frame(height: 132)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        VStack {
                            HStack {
                                Text("第 \(index + 1) 张")
                                    .font(.system(size: 9, weight: .semibold))
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
                                }
                                .accessibilityLabel("替换第 \(index + 1) 张主页封面")
                                Spacer()
                                Button { moveHero(at: index, by: -1) } label: {
                                    Image(systemName: "arrow.left.circle.fill")
                                }
                                .disabled(index == 0)
                                Button { moveHero(at: index, by: 1) } label: {
                                    Image(systemName: "arrow.right.circle.fill")
                                }
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
            Group {
                if let aboutPortraitURL {
                    ArtworkImage(url: aboutPortraitURL)
                } else {
                    Image("AboutPortrait")
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(height: 300)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            PhotosPicker(selection: $selectedAboutPortrait, matching: .images) {
                Label("从手机相册替换人物图", systemImage: "person.crop.rectangle.badge.plus")
                    .adminPrimaryButton()
            }
            .disabled(isPublishing)

            Text("建议使用 9:16 竖版人像。未发布新图时继续使用 App 内置照片。")
                .font(.caption2)
                .foregroundStyle(AppTheme.muted)
        }
    }

    private var launchPosterEditor: some View {
        AdminSection(title: "开屏海报", subtitle: "按日期自动投放；最近开始的有效海报优先展示") {
            PhotosPicker(selection: $selectedLaunchPoster, matching: .images) {
                Label("上传一张开屏海报", systemImage: "rectangle.portrait.badge.plus")
                    .adminPrimaryButton()
            }
            .disabled(isPublishing || launchPosterDrafts.count >= 12)

            ForEach($launchPosterDrafts) { $poster in
                VStack(alignment: .leading, spacing: 13) {
                    LaunchPosterAdminPreview(poster: poster)
                        .frame(height: 420)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 5))

                    PhotosPicker(
                        selection: replacementSelection { item in
                            Task { await replaceLaunchPoster(item, id: poster.id) }
                        },
                        matching: .images
                    ) {
                        Label("只替换这张海报图片", systemImage: "arrow.triangle.2.circlepath.camera")
                            .adminSecondaryButton()
                    }
                    .disabled(isPublishing)

                    Toggle("启用这张海报", isOn: $poster.isEnabled)
                        .tint(AppTheme.gold)

                    TextField("英文眉题", text: $poster.eyebrow)
                    TextField("海报标题", text: $poster.title)
                    TextField("海报副标题", text: $poster.subtitle)

                    DatePicker(
                        "开始日期",
                        selection: $poster.startsAt,
                        displayedComponents: .date
                    )
                    DatePicker(
                        "结束日期",
                        selection: $poster.endsAt,
                        displayedComponents: .date
                    )

                    Stepper(value: $poster.displaySeconds, in: 1.5...5, step: 0.5) {
                        Text("展示 \(poster.displaySeconds, specifier: "%.1f") 秒")
                    }

                    Button(role: .destructive) {
                        launchPosterDrafts.removeAll { $0.id == poster.id }
                    } label: {
                        Label("移除这张海报", systemImage: "minus.circle")
                    }
                    .font(.caption)
                }
                .padding(14)
                .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
            }

            Text("上方预览采用与真实开屏一致的裁切和文案位置。建议使用 9:16 竖版照片，最后点击底部“保存并发布全部修改”。")
                .font(.caption2)
                .foregroundStyle(AppTheme.muted)
        }
        .textFieldStyle(AdminTextFieldStyle())
    }

    private var showreelEditor: some View {
        AdminSection(title: "Showreel", subtitle: "更换视频、海报和展示文案") {
            ArtworkImage(url: showreelDraft.posterURL)
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
            ForEach($dramaDrafts) { $drama in
                VStack(alignment: .leading, spacing: 10) {
                    if let url = URL(string: drama.imageURL),
                       ContentSecurityPolicy.isTrustedMediaURL(url) {
                        ArtworkImage(url: url)
                            .frame(height: 180)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    PhotosPicker(
                        selection: replacementSelection { item in
                            Task { await replaceDramaPoster(item, id: drama.id) }
                        },
                        matching: .images
                    ) {
                        Label("从手机相册替换海报", systemImage: "photo.badge.plus")
                            .adminSecondaryButton()
                    }
                    .disabled(isPublishing)
                    TextField("剧名", text: $drama.title)
                    TextField("海报 HTTPS 地址（高级）", text: $drama.imageURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("观看页 HTTPS 地址", text: $drama.destinationURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Button(role: .destructive) {
                        dramaDrafts.removeAll { $0.id == drama.id }
                    } label: {
                        Label("移除这部作品", systemImage: "minus.circle")
                    }
                    .font(.caption)
                }
                .padding(14)
                .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
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

    private var publishControls: some View {
        VStack(spacing: 12) {
            Button { Task { await publishContent() } } label: {
                Label("保存并发布全部修改", systemImage: "icloud.and.arrow.up")
                    .adminPrimaryButton()
            }
            .disabled(isPublishing || !administratorEditorIsReady)

            Button("放弃未发布的文字修改") { loadDrafts() }
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
                .disabled(isPublishing || !administratorEditorIsReady)
        }
    }

    private var selectedPortfolioBinding: Binding<Int?> {
        Binding(
            get: { selectedPortfolioID ?? store.portfolios.first?.id },
            set: { selectedPortfolioID = $0 }
        )
    }

    private var selectedPortfolio: Portfolio? {
        let id = selectedPortfolioID ?? store.portfolios.first?.id
        return store.portfolios.first { $0.id == id }
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
        aboutPortraitURL = store.aboutPortraitURL
        launchPosterDrafts = store.launchPosters
        if let showreel = store.showreel {
            showreelDraft = showreel
            tagsText = showreel.tags.joined(separator: "、")
        }
        dramaDrafts = store.dramas.map(DramaDraft.init)
        if selectedPortfolioID.flatMap({ selectedID in
            store.portfolios.first(where: { $0.id == selectedID })
        }) == nil {
            selectedPortfolioID = store.portfolios.first?.id
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
        await performOperation(success: "关于页人物图已替换，等待发布") { contentLoadID in
            let media = try await uploadImage(item, prefix: "about-portrait")
            try ensureAdministratorOperationIsCurrent(contentLoadID)
            aboutPortraitURL = media.sourceURL
        }
        selectedAboutPortrait = nil
    }

    private func uploadLaunchPoster(_ item: PhotosPickerItem) async {
        await performOperation(success: "开屏海报已上传，设置日期后等待发布") { contentLoadID in
            let media = try await uploadImage(item, prefix: "launch-poster")
            try ensureAdministratorOperationIsCurrent(contentLoadID)
            let start = Calendar.current.startOfDay(for: .now)
            let end = Calendar.current.date(byAdding: .day, value: 30, to: start)
                ?? start.addingTimeInterval(30 * 86_400)
            launchPosterDrafts.append(
                LaunchPosterContent(
                    id: UUID().uuidString.lowercased(),
                    isEnabled: true,
                    imageURL: media.sourceURL,
                    eyebrow: "SEASONAL POSTER",
                    title: "易姝",
                    subtitle: "镜头之内，自有叙事。",
                    startsAt: start,
                    endsAt: end,
                    displaySeconds: 2.5
                )
            )
        }
        selectedLaunchPoster = nil
    }

    private func replaceLaunchPoster(_ item: PhotosPickerItem, id: String) async {
        await performOperation(success: "开屏图片已替换，原文案和投放日期保持不变") { contentLoadID in
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

private struct LaunchPosterAdminPreview: View {
    let poster: LaunchPosterContent

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ArtworkImage(url: poster.imageURL)
            LinearGradient(
                colors: [.black.opacity(0.12), .clear, AppTheme.ink.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )
            LaunchPosterTextBlock(poster: poster, compact: true)
            .padding(18)
        }
        .aspectRatio(9 / 16, contentMode: .fill)
    }
}

private struct DramaDraft: Identifiable {
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
                Text(title).font(.editorial(27))
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
            .padding(.vertical, 12)
            .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.white.opacity(0.1), lineWidth: 0.5)
            }
    }
}

private extension View {
    nonisolated func adminPrimaryButton() -> some View {
        frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(AppTheme.warmWhite, in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(AppTheme.ink)
            .font(.system(size: 14, weight: .semibold))
    }

    nonisolated func adminSecondaryButton() -> some View {
        frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(AppTheme.warmWhite)
            .font(.system(size: 13, weight: .medium))
    }
}
