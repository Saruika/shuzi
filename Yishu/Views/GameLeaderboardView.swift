import SwiftUI

/// Internal, approved-account rankings. Opening this view never publishes a run.
struct GameLeaderboardView: View {
    @ObservedObject var account: FanAccountStore
    @ObservedObject var store: GameLeaderboardStore
    let onClose: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var minimumNameColumnWidth: CGFloat = 160
    @State private var confirmsRemoval = false
    @State private var removalContext: FanNotificationContext?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    Text("每人保留最高成绩 · 同分按先上榜者排序")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.muted)
                    if account.gameLeaderboardContext == nil {
                        ContentUnavailableView("需要已审批账号", systemImage: "lock", description: Text("请使用 App 内已完成资料并获批的账号参与。离线游戏不受影响。"))
                    } else {
                        participation
                        if store.isWriting {
                            ProgressView("正在更新排行榜")
                                .frame(maxWidth: .infinity, minHeight: 120)
                                .accessibilityIdentifier("game-leaderboard-write-progress")
                        } else if store.isLoading && store.page == nil {
                            ProgressView("正在读取排行榜")
                                .frame(maxWidth: .infinity, minHeight: 120)
                        } else if let page = store.page {
                            if let mine = page.myEntry {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("我的最高成绩").font(.headline)
                                    rankRow(mine)
                                    Button("移除我的上榜记录", role: .destructive) {
                                        removalContext = account.gameLeaderboardContext
                                        confirmsRemoval = removalContext != nil
                                    }
                                        .frame(minHeight: 44)
                                        .disabled(store.isWriting || store.isLoading)
                                        .accessibilityIdentifier("game-leaderboard-remove")
                                }
                                .padding(16)
                                .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 12))
                            }
                            if page.entries.isEmpty {
                                ContentUnavailableView("还没有上榜成绩", systemImage: "trophy", description: Text("完成一局后，成绩会自动加入排行榜。"))
                            } else {
                                Text("最高成绩榜 · 前 100 名")
                                    .font(.headline)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(page.entries) { entry in
                                    rankRow(entry)
                                    Divider().overlay(AppTheme.muted.opacity(0.15))
                                }
                            }
                        }
                        if let message = store.errorMessage {
                            Text(message).font(.callout).foregroundStyle(AppTheme.warning)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("game-leaderboard-error")
                            Button("重新读取") { Task { await store.refresh(using: account) } }
                                .frame(minHeight: 44)
                                .disabled(store.isWriting || store.isLoading)
                        }
                    }
                    Text("完成游戏后自动提交成绩，每人保留最高成绩。排行榜仅向已审批的 App 用户展示昵称、成绩、出身、结局和上榜时间，不展示邮箱、抖音 ID 或身份码。你可以移除上榜记录，删除账号也会移除记录；再次完成游戏会重新自动上榜。同步需要联网，失败时可在此重试；待同步成绩仅保留在本次游戏的内存中，退出后不保留。")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(AppTheme.ink.ignoresSafeArea())
            .foregroundStyle(AppTheme.warmWhite)
            .navigationTitle("排行榜")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成", action: onClose).frame(minHeight: 44)
                        .accessibilityIdentifier("game-leaderboard-close")
                }
            }
            .themeNavigationChrome()
            .refreshable { await store.refresh(using: account) }
            .task(id: account.gameLeaderboardContext) { await store.refresh(using: account) }
            .onChange(of: account.gameLeaderboardContext) { _, context in
                confirmsRemoval = false
                removalContext = nil
                store.updateContext(context)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await store.refresh(using: account) } }
            }
            .alert("移除上榜记录？", isPresented: $confirmsRemoval) {
                Button("取消", role: .cancel) { removalContext = nil }
                Button("移除记录", role: .destructive) {
                    guard let expected = removalContext else { return }
                    removalContext = nil
                    Task {
                        guard account.gameLeaderboardContext == expected else { return }
                        await store.remove(using: account)
                    }
                }
                    .accessibilityIdentifier("game-leaderboard-confirm-remove")
            } message: {
                Text("只移除你的游戏排行榜记录，并清除本次尚未同步的成绩，不删除 App 账号、相册或其他资料。再次完成新的一局会自动上榜。")
            }
        }
    }

    private var participation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.pendingRuns.isEmpty ? "完成游戏自动上榜" : "\(store.pendingRuns.count) 局成绩待同步")
                .font(.headline)
            if !store.pendingRuns.isEmpty {
                Button {
                    Task { await store.flushCompletedRuns(using: account) }
                } label: {
                    Text("重试同步成绩")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.gold)
                .disabled(store.isLoading || store.isWriting)
                .accessibilityIdentifier("game-leaderboard-submit")
            }
        }
    }

    private func rankRow(_ entry: GameLeaderboardEntry) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stackedRankRow(entry)
            } else {
                ViewThatFits(in: .horizontal) {
                    horizontalRankRow(entry)
                    stackedRankRow(entry)
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func horizontalRankRow(_ entry: GameLeaderboardEntry) -> some View {
        HStack(alignment: .top, spacing: 14) {
            rankNumber(entry).frame(minWidth: 30)
            rankDetails(entry)
                // A long signed score must not compress the name to a sliver.
                // If these columns cannot fit, ViewThatFits chooses the stack.
                .frame(minWidth: minimumNameColumnWidth, alignment: .leading)
            Spacer(minLength: 4)
            Text("\(entry.score)").font(.headline.monospacedDigit())
                .fixedSize()
        }
    }

    private func stackedRankRow(_ entry: GameLeaderboardEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            rankNumber(entry)
            rankDetails(entry)
            Text("\(entry.score)").font(.headline.monospacedDigit())
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rankNumber(_ entry: GameLeaderboardEntry) -> some View {
        Text("\(entry.rank)")
            .font(.title3.weight(.semibold).monospacedDigit())
            .foregroundStyle(entry.rank <= 3 ? AppTheme.gold : AppTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func rankDetails(_ entry: GameLeaderboardEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: entry.displayName).font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if entry.isMe { Text("我").font(.caption).foregroundStyle(AppTheme.gold) }
            }
            Text(verbatim: "\(entry.endingTitle) · \(entry.originName)")
                .font(.subheadline).foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(entry.answered) 题 · \(entry.achievedAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption).foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
