import SwiftUI

struct FanCommunityView: View {
    @EnvironmentObject private var community: FanCommunityStore
    @EnvironmentObject private var notifications: NotificationStore
    @State private var showsLetterComposer = false

    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    header
                    notificationPrompt

                    if let content = community.content {
                        ForEach(content.posts) { post in
                            postCard(post, reactionsEnabled: content.features.reactionsEnabled)
                        }
                        ForEach(content.polls) { poll in
                            pollCard(poll, pollsEnabled: content.features.pollsEnabled)
                        }
                        letterSection(content)
                    } else if community.isLoading {
                        loadingState
                    } else {
                        unavailableState
                    }

                    safetyNote
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 90)
            }
            .refreshable { await community.refresh() }
            .scrollIndicators(.hidden)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            async let contentRefresh: Void = community.refresh()
            async let notificationRefresh: Void = notifications.refreshAuthorizationStatus()
            _ = await (contentRefresh, notificationRefresh)
        }
        .sheet(isPresented: $showsLetterComposer) {
            FanLetterComposerView()
                .environmentObject(community)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("YI SHU MOMENTS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(3.2)
                .foregroundStyle(AppTheme.gold)
            Text("易姝动态")
                .font(.editorial(40))
            HStack(spacing: 7) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(AppTheme.gold)
                Text("易姝发布 · 狐狸姐姐管理")
            }
            .font(.caption)
            .foregroundStyle(AppTheme.muted)
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var notificationPrompt: some View {
        if !notifications.isAuthorized {
            VStack(alignment: .leading, spacing: 13) {
                Label("不错过新作品和直播", systemImage: "bell.badge")
                    .font(.headline)
                Text("只有你主动开启后才会接收，也可以分别关闭作品或直播提醒。")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
                Button {
                    Task { await notifications.requestAuthorization() }
                } label: {
                    Text("开启通知")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(AppTheme.warmWhite, in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(AppTheme.ink)
                }
            }
            .padding(16)
            .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func postCard(_ post: FanPost, reactionsEnabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: post.kind.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.gold)
                    .frame(width: 36, height: 36)
                    .background(AppTheme.gold.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(post.kind.title)
                        .font(.headline)
                    Text("\(post.authorName) · \(post.managerLabel)")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                }
                Spacer()
                Text(post.publishedAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
            }

            Text(post.text)
                .font(.system(size: 16))
                .lineSpacing(6)
                .foregroundStyle(.white.opacity(0.88))

            if let externalURL = post.externalURL {
                Link(destination: externalURL) {
                    Label(post.kind == .live ? "进入直播间" : "打开作品", systemImage: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(AppTheme.gold.opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(AppTheme.gold)
                }
            }

            if reactionsEnabled {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { reactionButtons(post) }
                    VStack(spacing: 8) { reactionButtons(post) }
                }
            }
        }
        .padding(17)
        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder
    private func reactionButtons(_ post: FanPost) -> some View {
        ForEach(post.reactions) { reaction in
            Button {
                Task { await community.react(to: post.id, reactionID: reaction.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: reaction.systemImage)
                    Text(reaction.label)
                    Text("\(reaction.count)")
                        .foregroundStyle(AppTheme.muted)
                }
                .font(.caption)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    reaction.isSelected ? AppTheme.gold.opacity(0.2) : Color.white.opacity(0.05),
                    in: Capsule()
                )
                .foregroundStyle(reaction.isSelected ? AppTheme.gold : .white.opacity(0.82))
            }
            .buttonStyle(.plain)
            .disabled(community.isSubmitting)
        }
    }

    private func pollCard(_ poll: FanPoll, pollsEnabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("狐狸姐姐发起的投票", systemImage: "chart.bar.xaxis")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.gold)
            Text(poll.question)
                .font(.title3.weight(.semibold))

            ForEach(poll.options) { option in
                Button {
                    Task { await community.vote(in: poll.id, optionID: option.id) }
                } label: {
                    ZStack(alignment: .leading) {
                        GeometryReader { geometry in
                            let fraction = poll.totalVotes > 0
                                ? Double(option.voteCount) / Double(poll.totalVotes)
                                : 0
                            Rectangle()
                                .fill(AppTheme.gold.opacity(option.isSelected ? 0.24 : 0.1))
                                .frame(width: geometry.size.width * fraction)
                        }
                        HStack {
                            Image(systemName: option.isSelected ? "checkmark.circle.fill" : "circle")
                            Text(option.label)
                            Spacer()
                            Text("\(option.voteCount)")
                                .foregroundStyle(AppTheme.muted)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 13)
                    }
                    .frame(height: 46)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(option.isSelected ? AppTheme.gold : .white.opacity(0.86))
                }
                .buttonStyle(.plain)
                .disabled(!poll.isOpen || !pollsEnabled || community.isSubmitting)
            }

            Text(poll.isOpen ? "共 \(poll.totalVotes) 人参与，可修改选择" : "投票已结束 · 共 \(poll.totalVotes) 人参与")
                .font(.caption2)
                .foregroundStyle(AppTheme.muted)
        }
        .padding(17)
        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 9))
    }

    private func letterSection(_ content: FanCommunityManifest) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("写给易姝", systemImage: "envelope.badge")
                .font(.headline)
            Text(content.lettersNotice)
                .font(.caption)
                .lineSpacing(4)
                .foregroundStyle(AppTheme.muted)
            Button {
                showsLetterComposer = true
            } label: {
                Text(content.features.lettersEnabled ? "写一封私密粉丝信" : "粉丝信正在准备中")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        content.features.lettersEnabled ? AppTheme.warmWhite : Color.white.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .foregroundStyle(content.features.lettersEnabled ? AppTheme.ink : AppTheme.muted)
            }
            .disabled(!content.features.lettersEnabled)
        }
        .padding(17)
        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 9))
    }

    private var safetyNote: some View {
        Label("互动内容由狐狸姐姐审核管理。粉丝信不会公开展示，也不会包含在相册订阅数据中。", systemImage: "lock.shield")
            .font(.caption2)
            .lineSpacing(4)
            .foregroundStyle(AppTheme.muted)
            .padding(.horizontal, 4)
    }

    private var loadingState: some View {
        HStack(spacing: 12) {
            ProgressView().tint(AppTheme.gold)
            Text("正在读取易姝的最新动态…")
                .foregroundStyle(AppTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var unavailableState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(AppTheme.gold)
            Text("动态空间正在准备")
                .font(.headline)
            Text(community.errorMessage ?? "稍后下拉刷新即可，这不会影响作品和影视内容。")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(AppTheme.muted)
            Button("重新加载") { Task { await community.refresh() } }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.gold)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
    }
}

private struct FanLetterComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var community: FanCommunityStore
    @State private var nickname = ""
    @State private var message = ""
    @State private var consent = false
    @State private var feedback: String?
    @State private var submitted = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("写给易姝")
                                .font(.editorial(36))
                            Text("狐狸姐姐会先审核并整理，再转交给易姝。内容不会公开展示。")
                                .font(.caption)
                                .foregroundStyle(AppTheme.muted)
                        }

                        TextField("昵称（可不填）", text: $nickname)
                            .textInputAutocapitalization(.never)
                            .padding(13)
                            .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))

                        VStack(alignment: .trailing, spacing: 7) {
                            TextEditor(text: $message)
                                .frame(minHeight: 210)
                                .scrollContentBackground(.hidden)
                                .padding(9)
                                .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
                                .onChange(of: message) { _, value in
                                    if value.count > 600 { message = String(value.prefix(600)) }
                                }
                            Text("\(message.count) / 600")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.muted)
                        }

                        Toggle(isOn: $consent) {
                            Text("我了解内容将经过自动规则与狐狸姐姐人工审核，并同意为转交目的保存这封信。")
                                .font(.caption)
                        }
                        .tint(AppTheme.gold)

                        if let feedback {
                            Label(feedback, systemImage: submitted ? "checkmark.circle" : "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(submitted ? AppTheme.gold : .orange)
                        }

                        Button {
                            Task { await submit() }
                        } label: {
                            HStack {
                                if community.isSubmitting { ProgressView().tint(AppTheme.ink) }
                                Text(community.isSubmitting ? "正在安全提交" : "交给狐狸姐姐")
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(AppTheme.warmWhite, in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(AppTheme.ink)
                        }
                        .disabled(
                            community.isSubmitting || submitted || !consent
                                || message.trimmingCharacters(in: .whitespacesAndNewlines).count < 10
                                || nickname.count > 24
                        )
                    }
                    .padding(20)
                }
            }
            .navigationTitle("私密粉丝信")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func submit() async {
        do {
            let receipt = try await community.sendLetter(
                nickname: nickname,
                message: message,
                consent: consent
            )
            feedback = receipt.message
            submitted = true
        } catch {
            feedback = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            submitted = false
        }
    }
}
