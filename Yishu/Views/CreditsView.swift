import AVFoundation
import SwiftUI

struct CreditsView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var inlinePlayer: AVPlayer?
    @State private var isInlinePlaying = false
    @State private var isInlineMuted = false
    @State private var showVideoPlaybackError = false
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 12)]

    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    header
                    if let showreel = store.showreel {
                        showreelSection(showreel)
                    }
                    credits
                    collaboration
                }
                .padding(.bottom, 54)
            }
            .scrollIndicators(.hidden)
            .contentMargins(.bottom, 84, for: .scrollContent)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.ink, for: .navigationBar)
        .onAppear {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-play-showreel-for-visual-testing"),
               inlinePlayer == nil {
                playInline()
            }
#endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard notificationBelongsToInlinePlayer(notification) else { return }
            stopInlinePlayback()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { notification in
            guard notificationBelongsToInlinePlayer(notification) else { return }
            stopInlinePlayback()
            showVideoPlaybackError = true
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active, inlinePlayer != nil else { return }
            pauseInlinePlayback()
        }
        .onDisappear { stopInlinePlayback() }
        .alert("视频暂时无法播放", isPresented: $showVideoPlaybackError) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text("请检查网络后重试。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SCREEN CREDITS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(3)
                .foregroundStyle(AppTheme.gold)
            Text("影视履历")
                .font(.editorial(42))
                .accessibilityIdentifier("credits-heading")
            Text("公开出演短剧与演员影像片段")
                .font(.subheadline)
                .foregroundStyle(AppTheme.muted)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private func showreelSection(_ showreel: ShowreelContent) -> some View {
        Group {
            if let inlinePlayer {
                ZStack(alignment: .bottomTrailing) {
                    ArtworkVideoSurface(player: inlinePlayer)
                        .accessibilityLabel(isInlinePlaying ? "正在播放易姝演员 Showreel" : "易姝演员 Showreel 已暂停")

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.48)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .allowsHitTesting(false)

                    HStack(spacing: 10) {
                        VideoControlButton(
                            systemName: isInlinePlaying ? "pause.fill" : "play.fill",
                            accessibilityLabel: isInlinePlaying ? "暂停视频" : "继续播放视频",
                            action: toggleInlinePlayback
                        )

                        VideoControlButton(
                            systemName: isInlineMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            accessibilityLabel: isInlineMuted ? "恢复视频声音" : "将视频静音",
                            action: toggleInlineMute
                        )
                    }
                    .padding(14)
                }
                .aspectRatio(1.5, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Button { playInline() } label: {
                    ZStack(alignment: .bottomLeading) {
                        ArtworkImage(url: showreel.posterURL, contentMode: .fit)
                            .aspectRatio(1.5, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .accessibilityHidden(true)
                        LinearGradient(colors: [.clear, .black.opacity(0.86)], startPoint: .center, endPoint: .bottom)
                        HStack(alignment: .bottom) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(showreel.eyebrow)
                                    .font(.system(size: 9, weight: .semibold))
                                    .tracking(1.7)
                                    .foregroundStyle(AppTheme.gold)
                                Text(showreel.title)
                                    .font(.editorial(25))
                                Text(showreel.tags.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.68))
                            }
                            Spacer()
                            Image(systemName: "play.fill")
                                .foregroundStyle(.black)
                                .frame(width: 52, height: 52)
                                .background(AppTheme.warmWhite, in: Circle())
                        }
                        .padding(18)
                    }
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("showreel-play")
                .accessibilityLabel("在当前页播放易姝 2026 演员 Showreel，时长 21 秒")
            }
        }
        .padding(.horizontal, 20)
    }

    private var credits: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeading(eyebrow: "SELECTED DRAMA", title: "代表短剧", trailing: "\(store.dramas.count) 部")

            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(store.dramas) { drama in
                    VStack(alignment: .leading, spacing: 10) {
                        Link(destination: drama.destinationURL) {
                            ArtworkImage(url: drama.imageURL, contentMode: .fit)
                                .aspectRatio(3 / 4, contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .background(AppTheme.elevatedInk)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        .buttonStyle(.plain)

                        Text(drama.title)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(2, reservesSpace: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private func playInline() {
        guard let showreel = store.showreel else { return }
        showVideoPlaybackError = false
        VideoAudioSession.activate()
        let player = AVPlayer(url: showreel.videoURL)
        player.isMuted = false
        player.volume = 1
        inlinePlayer = player
        isInlineMuted = false
        isInlinePlaying = true
        player.play()
    }

    private func toggleInlinePlayback() {
        guard inlinePlayer != nil else { return }
        if isInlinePlaying {
            pauseInlinePlayback()
        } else {
            VideoAudioSession.activate()
            inlinePlayer?.play()
            isInlinePlaying = true
        }
    }

    private func pauseInlinePlayback() {
        inlinePlayer?.pause()
        isInlinePlaying = false
        VideoAudioSession.deactivate()
    }

    private func toggleInlineMute() {
        guard let inlinePlayer else { return }
        isInlineMuted.toggle()
        inlinePlayer.isMuted = isInlineMuted
    }

    private func stopInlinePlayback() {
        inlinePlayer?.pause()
        inlinePlayer?.replaceCurrentItem(with: nil)
        inlinePlayer = nil
        isInlinePlaying = false
        isInlineMuted = false
        VideoAudioSession.deactivate()
    }

    private func notificationBelongsToInlinePlayer(_ notification: Notification) -> Bool {
        guard let item = notification.object as? AVPlayerItem else { return false }
        return item === inlinePlayer?.currentItem
    }

    private var collaboration: some View {
        VStack(spacing: 14) {
            Text("CASTING & COLLABORATION")
                .font(.system(size: 9, weight: .semibold))
                .tracking(2.4)
                .foregroundStyle(AppTheme.gold)
            Text("角色与品牌合作")
                .font(.editorial(27))
            CollaborationContactButton {
                Label("发送合作邀约", systemImage: "arrow.up.right")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 13)
                    .background(AppTheme.warmWhite, in: Capsule())
                    .foregroundStyle(AppTheme.ink)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 20)
    }
}

private struct VideoControlButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.18), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
