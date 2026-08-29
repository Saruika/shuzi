import SwiftUI

struct FanCommunityAdminView: View {
    @EnvironmentObject private var admin: AdminSessionStore
    @State private var dashboard: FanCommunityAdminDashboard?
    @State private var features = FanFeatureFlags(
        reactionsEnabled: true,
        pollsEnabled: true,
        lettersEnabled: false
    )
    @State private var blockTermsText = ""
    @State private var reviewTermsText = ""
    @State private var noteText = ""
    @State private var pollQuestion = ""
    @State private var pollOptionsText = ""
    @State private var isWorking = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    statusSection
                    featureSection
                    moderationSection
                    noteSection
                    pollSection
                    letterSection
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 70)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("粉丝互动工作台")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(AppTheme.ink, for: .navigationBar)
        .task { await load() }
    }

    private var statusSection: some View {
        AdminFanSection(title: "自动同步状态", subtitle: "服务器每十分钟检查；相同作品或直播场次只通知一次") {
            statusRow(
                "Apple 推送",
                ready: dashboard?.pushReady == true,
                detail: dashboard?.pushReady == true
                    ? "已登记 \(dashboard?.activePushDevices ?? 0) 台设备"
                    : "等待 APNs 私钥与服务配置"
            )
            statusRow(
                "抖音新作品",
                ready: source("douyin")?.ready == true && source("douyin")?.lastError?.isEmpty != false,
                detail: sourceDetail("douyin", fallback: "等待创作者授权与 video.list 权限")
            )
            statusRow(
                "小红书 / 直播",
                ready: source("signedFeed")?.ready == true && source("signedFeed")?.lastError?.isEmpty != false,
                detail: sourceDetail("signedFeed", fallback: "等待合规数据适配器")
            )

            if isWorking {
                HStack(spacing: 9) {
                    ProgressView().tint(AppTheme.gold)
                    Text("正在安全保存…")
                }
                .font(.caption)
                .foregroundStyle(AppTheme.gold)
            } else if let message {
                Label(message, systemImage: failed ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(failed ? .orange : AppTheme.gold)
            }

            Button("刷新状态") { Task { await load() } }
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.gold)
        }
    }

    private var featureSection: some View {
        AdminFanSection(title: "功能开关", subtitle: "紧急情况下可独立关闭任一互动入口") {
            Toggle("固定回应", isOn: $features.reactionsEnabled)
            Toggle("投票", isOn: $features.pollsEnabled)
            Toggle("私密粉丝信", isOn: $features.lettersEnabled)
            Button {
                Task { await saveSettings() }
            } label: {
                Label("保存功能开关", systemImage: "checkmark.shield")
                    .fanAdminPrimaryButton()
            }
            .disabled(isWorking)
            Text("审核词表为空时，服务端会拒绝开启粉丝信。")
                .font(.caption2)
                .foregroundStyle(AppTheme.muted)
        }
        .tint(AppTheme.gold)
    }

    private var moderationSection: some View {
        AdminFanSection(title: "内容安全规则", subtitle: "每行一个词；规则只保存在服务端，不下发给普通用户") {
            VStack(alignment: .leading, spacing: 7) {
                Text("直接拦截")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.gold)
                TextEditor(text: $blockTermsText)
                    .frame(minHeight: 130)
                    .fanAdminEditor()
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("转人工复核")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.gold)
                TextEditor(text: $reviewTermsText)
                    .frame(minHeight: 130)
                    .fanAdminEditor()
            }
            Button {
                Task { await saveSettings() }
            } label: {
                Label("保存并热更新规则", systemImage: "shield.lefthalf.filled")
                    .fanAdminPrimaryButton()
            }
            .disabled(isWorking)
        }
    }

    private var noteSection: some View {
        AdminFanSection(title: "易姝日常动态", subtitle: "平台作品由服务器自动同步，这里只写 App 内日常") {
            TextEditor(text: $noteText)
                .frame(minHeight: 130)
                .fanAdminEditor()
                .onChange(of: noteText) { _, value in
                    if value.count > 500 { noteText = String(value.prefix(500)) }
                }
            HStack {
                Text("以易姝名义发布 · 狐狸姐姐管理")
                Spacer()
                Text("\(noteText.count) / 500")
            }
            .font(.caption2)
            .foregroundStyle(AppTheme.muted)
            Button {
                Task { await publishNote() }
            } label: {
                Label("发布到动态页", systemImage: "paperplane.fill")
                    .fanAdminPrimaryButton()
            }
            .disabled(isWorking || noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var pollSection: some View {
        AdminFanSection(title: "发布投票", subtitle: "填写 2 至 4 个选项，每行一个") {
            TextField("投票问题", text: $pollQuestion)
                .fanAdminTextField()
            TextEditor(text: $pollOptionsText)
                .frame(minHeight: 110)
                .fanAdminEditor()
            Button {
                Task { await publishPoll() }
            } label: {
                Label("发布投票", systemImage: "chart.bar.xaxis")
                    .fanAdminPrimaryButton()
            }
            .disabled(isWorking || pollQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private var letterSection: some View {
        AdminFanSection(title: "私密信箱", subtitle: "所有内容先审核，不会出现在公开接口") {
            let pendingLetters = dashboard?.letters.filter { $0.status != "archived" } ?? []
            if pendingLetters.isEmpty {
                Text("目前没有待处理的粉丝信。")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
            } else {
                ForEach(pendingLetters) { letter in
                    VStack(alignment: .leading, spacing: 11) {
                        HStack {
                            Text(letter.nickname.isEmpty ? "匿名粉丝" : letter.nickname)
                                .font(.headline)
                            Spacer()
                            Text(letter.moderationBucket == "review" ? "需重点复核" : "待审核")
                                .font(.caption2)
                                .foregroundStyle(letter.moderationBucket == "review" ? .orange : AppTheme.gold)
                        }
                        Text(letter.message)
                            .font(.subheadline)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                        Text(letter.submittedAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption2)
                            .foregroundStyle(AppTheme.muted)
                        HStack(spacing: 9) {
                            Button("已转交易姝") {
                                Task { await updateLetter(letter.id, status: "delivered") }
                            }
                            .fanAdminSmallButton()
                            Button("归档") {
                                Task { await updateLetter(letter.id, status: "archived") }
                            }
                            .fanAdminSmallButton()
                        }
                        .disabled(isWorking)
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func statusRow(_ title: String, ready: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: ready ? "checkmark.circle.fill" : "clock.badge.exclamationmark")
                .foregroundStyle(ready ? AppTheme.gold : .orange)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(AppTheme.muted)
            }
        }
    }

    private func source(_ key: String) -> FanSourceStatus? {
        dashboard?.sourceStatus?[key]
    }

    private func sourceDetail(_ key: String, fallback: String) -> String {
        if let error = source(key)?.lastError, !error.isEmpty { return error }
        if let success = source(key)?.lastSuccess {
            return "最近同步 \(success.formatted(.relative(presentation: .named)))"
        }
        return fallback
    }

    private func load() async {
        await perform(success: nil) {
            apply(try await admin.fetchFanCommunityDashboard())
        }
    }

    private func saveSettings() async {
        let blockTerms = terms(from: blockTermsText)
        let reviewTerms = terms(from: reviewTermsText)
        await perform(success: "功能与审核规则已更新") {
            apply(try await admin.updateFanCommunitySettings(
                features: features,
                blockTerms: blockTerms,
                reviewTerms: reviewTerms
            ))
        }
    }

    private func publishNote() async {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        await perform(success: "易姝动态已发布") {
            apply(try await admin.createFanNote(text: text))
            noteText = ""
        }
    }

    private func publishPoll() async {
        let options = terms(from: pollOptionsText).prefix(4)
        guard options.count >= 2 else {
            failed = true
            message = "请填写 2 至 4 个不同选项。"
            return
        }
        await perform(success: "投票已发布") {
            apply(try await admin.createFanPoll(
                question: pollQuestion.trimmingCharacters(in: .whitespacesAndNewlines),
                options: Array(options)
            ))
            pollQuestion = ""
            pollOptionsText = ""
        }
    }

    private func updateLetter(_ id: Int, status: String) async {
        await perform(success: status == "delivered" ? "已标记为转交易姝" : "粉丝信已归档") {
            apply(try await admin.updateFanLetterStatus(id: id, status: status))
        }
    }

    private func perform(success: String?, operation: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        failed = false
        if success != nil { message = nil }
        defer { isWorking = false }
        do {
            try await operation()
            if let success { message = success }
        } catch {
            failed = true
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func apply(_ value: FanCommunityAdminDashboard) {
        dashboard = value
        features = value.features
        blockTermsText = value.moderation.blockTerms.joined(separator: "\n")
        reviewTermsText = value.moderation.reviewTerms.joined(separator: "\n")
    }

    private func terms(from text: String) -> [String] {
        var seen = Set<String>()
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

private struct AdminFanSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(AppTheme.muted)
            }
            content
        }
    }
}

private extension View {
    func fanAdminPrimaryButton() -> some View {
        frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(AppTheme.warmWhite, in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(AppTheme.ink)
            .font(.subheadline.weight(.semibold))
    }

    func fanAdminSmallButton() -> some View {
        frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(AppTheme.gold.opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(AppTheme.gold)
            .font(.caption.weight(.semibold))
    }

    func fanAdminEditor() -> some View {
        scrollContentBackground(.hidden)
            .padding(9)
            .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.08)))
    }

    func fanAdminTextField() -> some View {
        padding(13)
            .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.08)))
    }
}
