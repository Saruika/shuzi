import AVFoundation
import SwiftUI

struct CreditsView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var inlinePlayer: AVPlayer?
    @State private var isInlinePlaying = false
    @State private var isInlineMuted = false
    @State private var isInlineBuffering = false
    @State private var isInlineEnded = false
    @State private var isInlineSeeking = false
    @State private var wasInlinePlayingBeforeSeek = false
    @State private var inlineCurrentTime: Double = 0
    @State private var inlineDuration: Double = 0
    @State private var showVideoPlaybackError = false
    @State private var playbackMonitorTask: Task<Void, Never>?
    @State private var playbackWaitStartedAt: Date?
    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 12)]
    }

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
            .floatingTabBarScrollClearance()
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
            finishInlinePlayback()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { notification in
            guard notificationBelongsToInlinePlayer(notification) else { return }
            stopInlinePlayback()
            showVideoPlaybackError = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemPlaybackStalled)) { notification in
            guard notificationBelongsToInlinePlayer(notification), isInlinePlaying else { return }
            isInlineBuffering = true
            playbackWaitStartedAt = playbackWaitStartedAt ?? .now
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active, inlinePlayer != nil else { return }
            pauseInlinePlayback()
        }
        .onDisappear { stopInlinePlayback() }
        .alert("视频暂时无法播放", isPresented: $showVideoPlaybackError) {
            Button("重新播放") { playInline() }
            Button("知道了", role: .cancel) { }
        } message: {
            Text("连接中断或等待时间过长，请检查网络后重试。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SCREEN CREDITS")
                .font(.caption2.weight(.semibold))
                .tracking(3)
                .foregroundStyle(AppTheme.gold)
            Text("影视履历")
                .font(.system(.largeTitle, design: .serif))
                .accessibilityIdentifier("credits-heading")
                .accessibilityAddTraits(.isHeader)
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
                VStack(spacing: 0) {
                    ZStack {
                        ArtworkVideoSurface(player: inlinePlayer, videoGravity: .resizeAspect)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("影片画面，\(showreel.title)，\(showreel.summary)")
                            .accessibilityValue(inlinePlaybackStateLabel)

                        if isInlineBuffering {
                            VStack(spacing: 9) {
                                ProgressView()
                                    .tint(.white)
                                Text("正在缓冲")
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(.black.opacity(0.68), in: Capsule())
                            .allowsHitTesting(false)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("视频正在缓冲，播放控制仍可使用")
                            .accessibilityAddTraits(.updatesFrequently)
                        } else if isInlineEnded {
                            VStack(spacing: 8) {
                                Image(systemName: "arrow.counterclockwise.circle.fill")
                                    .font(.title)
                                Text("播放结束")
                                    .font(.headline)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 14))
                            .allowsHitTesting(false)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("视频播放结束，可使用下方按钮重新播放")
                        }
                    }
                    .aspectRatio(1.5, contentMode: .fit)

                    inlinePlaybackControls(showreel)
                }
                .frame(maxWidth: .infinity)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Button { playInline() } label: {
                    showreelPoster(showreel)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("showreel-play")
                .accessibilityLabel("在当前页播放\(showreel.title)")
                .accessibilityValue("内容简介：\(showreel.summary)，时长 \(showreel.durationLabel)")
            }
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private func showreelPoster(_ showreel: ShowreelContent) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 0) {
                ArtworkImage(url: showreel.posterURL, contentMode: .fit)
                    .aspectRatio(1.5, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 10) {
                    showreelMetadata(showreel)
                    Label("播放影片", systemImage: "play.fill")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(AppTheme.warmWhite, in: Capsule())
                        .foregroundStyle(.black)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(.black)
            }
        } else {
            ZStack(alignment: .bottomLeading) {
                ArtworkImage(url: showreel.posterURL, contentMode: .fit)
                    .aspectRatio(1.5, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                LinearGradient(colors: [.clear, .black.opacity(0.86)], startPoint: .center, endPoint: .bottom)
                HStack(alignment: .bottom, spacing: 12) {
                    showreelMetadata(showreel)
                    Spacer(minLength: 8)
                    Image(systemName: "play.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(minWidth: 52, minHeight: 52)
                        .background(AppTheme.warmWhite, in: Circle())
                }
                .padding(18)
            }
        }
    }

    private func showreelMetadata(_ showreel: ShowreelContent) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(showreel.eyebrow)
                .font(.caption2.weight(.semibold))
                .tracking(1.7)
                .foregroundStyle(AppTheme.gold)
            Text(showreel.title)
                .font(.system(.title2, design: .serif))
            Text(showreel.tags.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func inlinePlaybackControls(_ showreel: ShowreelContent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Slider(
                value: Binding(
                    get: { min(max(inlineCurrentTime, 0), max(inlineDuration, 1)) },
                    set: { updateInlineSeekPosition($0) }
                ),
                in: 0...max(inlineDuration, 1),
                onEditingChanged: handleInlineSeekEditing
            )
            .tint(AppTheme.gold)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .disabled(inlineDuration <= 0)
            .accessibilityIdentifier("showreel-progress")
            .accessibilityLabel("视频播放进度")
            .accessibilityValue(inlineProgressAccessibilityValue(showreel))
            .accessibilityHint("上下轻扫可调整播放位置")

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    inlineTimeLabel(showreel)
                    Spacer(minLength: 8)
                    inlineControlButtons
                }

                VStack(alignment: .leading, spacing: 10) {
                    inlineTimeLabel(showreel)
                    inlineControlButtons
                }
            }

            Text("内容简介：\(showreel.summary)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(.black)
    }

    private func inlineTimeLabel(_ showreel: ShowreelContent) -> some View {
        Text("\(formattedPlaybackTime(inlineCurrentTime)) / \(inlineDuration > 0 ? formattedPlaybackTime(inlineDuration) : showreel.durationLabel)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.78))
            .accessibilityHidden(true)
    }

    private var inlineControlButtons: some View {
        HStack(spacing: 10) {
            VideoControlButton(
                systemName: isInlineEnded ? "arrow.counterclockwise" : (isInlinePlaying ? "pause.fill" : "play.fill"),
                accessibilityLabel: isInlineEnded ? "重新播放视频" : (isInlinePlaying ? "暂停视频" : "继续播放视频"),
                accessibilityIdentifier: "showreel-playback-control",
                action: toggleInlinePlayback
            )

            VideoControlButton(
                systemName: isInlineMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                accessibilityLabel: isInlineMuted ? "恢复视频声音" : "将视频静音",
                accessibilityIdentifier: "showreel-mute-control",
                action: toggleInlineMute
            )
        }
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
                        .accessibilityIdentifier("drama-link-\(drama.id)")
                        .accessibilityLabel("观看\(drama.title)")
                        .accessibilityHint("打开外部播放页面")

                        Text(drama.title)
                            .font(.subheadline.weight(.medium))
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
        player.automaticallyWaitsToMinimizeStalling = true
        player.isMuted = false
        player.volume = 1
        inlinePlayer = player
        isInlineMuted = false
        isInlinePlaying = true
        isInlineBuffering = true
        isInlineEnded = false
        isInlineSeeking = false
        wasInlinePlayingBeforeSeek = false
        inlineCurrentTime = 0
        inlineDuration = 0
        playbackWaitStartedAt = .now
        startPlaybackMonitor(for: player)
        player.play()
    }

    private func toggleInlinePlayback() {
        guard inlinePlayer != nil else { return }
        if isInlineEnded {
            replayInlinePlayback()
            return
        }
        if isInlinePlaying {
            pauseInlinePlayback()
        } else {
            VideoAudioSession.activate()
            inlinePlayer?.play()
            isInlinePlaying = true
            isInlineBuffering = inlinePlayer?.timeControlStatus != .playing
            playbackWaitStartedAt = isInlineBuffering ? .now : nil
        }
    }

    private func pauseInlinePlayback() {
        inlinePlayer?.pause()
        isInlinePlaying = false
        isInlineBuffering = false
        playbackWaitStartedAt = nil
        VideoAudioSession.deactivate()
    }

    private func toggleInlineMute() {
        guard let inlinePlayer else { return }
        isInlineMuted.toggle()
        inlinePlayer.isMuted = isInlineMuted
    }

    private func replayInlinePlayback() {
        guard let inlinePlayer else { return }
        VideoAudioSession.activate()
        inlinePlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        inlineCurrentTime = 0
        isInlineEnded = false
        isInlinePlaying = true
        isInlineBuffering = inlinePlayer.timeControlStatus != .playing
        playbackWaitStartedAt = isInlineBuffering ? .now : nil
        startPlaybackMonitor(for: inlinePlayer)
        inlinePlayer.play()
    }

    private func finishInlinePlayback() {
        playbackMonitorTask?.cancel()
        playbackMonitorTask = nil
        inlinePlayer?.pause()
        if inlineDuration > 0 {
            inlineCurrentTime = inlineDuration
        } else if let finalTime = inlinePlayer?.currentTime().seconds,
                  finalTime.isFinite,
                  finalTime >= 0 {
            inlineCurrentTime = finalTime
        }
        isInlinePlaying = false
        isInlineBuffering = false
        isInlineEnded = true
        isInlineSeeking = false
        wasInlinePlayingBeforeSeek = false
        playbackWaitStartedAt = nil
        VideoAudioSession.deactivate()
    }

    private func updateInlineSeekPosition(_ proposedPosition: Double) {
        let maximum = max(inlineDuration, 1)
        inlineCurrentTime = min(max(proposedPosition, 0), maximum)
        if inlineDuration > 0, inlineCurrentTime < inlineDuration - 0.25 {
            isInlineEnded = false
        }
        // A touch drag is committed when editing ends. VoiceOver adjusts a
        // Slider without that gesture lifecycle, so apply those discrete
        // changes immediately to keep the spoken control functional.
        if !isInlineSeeking, inlineDuration > 0 {
            inlinePlayer?.seek(
                to: CMTime(seconds: inlineCurrentTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
    }

    private func handleInlineSeekEditing(_ isEditing: Bool) {
        guard let inlinePlayer, inlineDuration > 0 else { return }

        if isEditing {
            isInlineSeeking = true
            wasInlinePlayingBeforeSeek = isInlinePlaying
            inlinePlayer.pause()
            isInlinePlaying = false
            isInlineBuffering = false
            playbackWaitStartedAt = nil
            return
        }

        inlinePlayer.seek(
            to: CMTime(seconds: inlineCurrentTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        isInlineSeeking = false
        isInlineEnded = inlineCurrentTime >= inlineDuration - 0.25

        if wasInlinePlayingBeforeSeek, !isInlineEnded {
            VideoAudioSession.activate()
            inlinePlayer.play()
            isInlinePlaying = true
            isInlineBuffering = inlinePlayer.timeControlStatus != .playing
            playbackWaitStartedAt = isInlineBuffering ? .now : nil
        } else {
            VideoAudioSession.deactivate()
        }
        wasInlinePlayingBeforeSeek = false
    }

    private func stopInlinePlayback() {
        playbackMonitorTask?.cancel()
        playbackMonitorTask = nil
        inlinePlayer?.pause()
        inlinePlayer?.replaceCurrentItem(with: nil)
        inlinePlayer = nil
        isInlinePlaying = false
        isInlineMuted = false
        isInlineBuffering = false
        isInlineEnded = false
        isInlineSeeking = false
        wasInlinePlayingBeforeSeek = false
        inlineCurrentTime = 0
        inlineDuration = 0
        playbackWaitStartedAt = nil
        VideoAudioSession.deactivate()
    }

    private func startPlaybackMonitor(for player: AVPlayer) {
        playbackMonitorTask?.cancel()
        playbackMonitorTask = Task { @MainActor in
            while !Task.isCancelled, inlinePlayer === player {
                if player.currentItem?.status == .failed {
                    stopInlinePlayback()
                    showVideoPlaybackError = true
                    return
                }

                if !isInlineSeeking {
                    let currentTime = player.currentTime().seconds
                    if currentTime.isFinite, currentTime >= 0 {
                        inlineCurrentTime = currentTime
                    }

                    if let knownDuration = knownInlineDuration(for: player) {
                        inlineDuration = knownDuration
                        inlineCurrentTime = min(inlineCurrentTime, knownDuration)
                    }
                }

                if isInlinePlaying {
                    if player.timeControlStatus == .playing {
                        isInlineBuffering = false
                        playbackWaitStartedAt = nil
                    } else {
                        isInlineBuffering = true
                        playbackWaitStartedAt = playbackWaitStartedAt ?? .now
                        if let startedAt = playbackWaitStartedAt,
                           Date().timeIntervalSince(startedAt) > 20 {
                            stopInlinePlayback()
                            showVideoPlaybackError = true
                            return
                        }
                    }
                }

                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
        }
    }

    private func knownInlineDuration(for player: AVPlayer) -> Double? {
        if let seconds = player.currentItem?.duration.seconds,
           seconds.isFinite,
           seconds > 0 {
            return seconds
        }

        guard let timeRange = player.currentItem?.seekableTimeRanges.last?.timeRangeValue else {
            return nil
        }
        let seconds = CMTimeRangeGetEnd(timeRange).seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    private var inlinePlaybackStateLabel: String {
        if isInlineEnded { return "播放结束" }
        if isInlineBuffering { return "正在缓冲" }
        if isInlinePlaying { return "正在播放" }
        return "已暂停"
    }

    private func inlineProgressAccessibilityValue(_ showreel: ShowreelContent) -> String {
        let current = spokenPlaybackTime(inlineCurrentTime)
        let total = inlineDuration > 0
            ? spokenPlaybackTime(inlineDuration)
            : spokenDurationLabel(showreel.durationLabel)
        return "已播放 \(current)，总时长 \(total)"
    }

    private func formattedPlaybackTime(_ seconds: Double) -> String {
        let wholeSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = wholeSeconds / 3_600
        let minutes = (wholeSeconds % 3_600) / 60
        let remainingSeconds = wholeSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    private func spokenPlaybackTime(_ seconds: Double) -> String {
        let wholeSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = wholeSeconds / 3_600
        let minutes = (wholeSeconds % 3_600) / 60
        let remainingSeconds = wholeSeconds % 60
        let hourPart = hours > 0 ? "\(hours) 小时" : ""
        let minutePart = minutes > 0 ? "\(minutes) 分" : ""
        let secondPart = "\(remainingSeconds) 秒"
        return [hourPart, minutePart, secondPart]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func spokenDurationLabel(_ label: String) -> String {
        let components = label
            .split(separator: ":")
            .compactMap { Int($0) }
        switch components.count {
        case 2:
            return spokenPlaybackTime(Double(components[0] * 60 + components[1]))
        case 3:
            return spokenPlaybackTime(Double(components[0] * 3_600 + components[1] * 60 + components[2]))
        default:
            return label
        }
    }

    private func notificationBelongsToInlinePlayer(_ notification: Notification) -> Bool {
        guard let item = notification.object as? AVPlayerItem else { return false }
        return item === inlinePlayer?.currentItem
    }

    private var collaboration: some View {
        VStack(spacing: 14) {
            Text("CASTING & COLLABORATION")
                .font(.caption2.weight(.semibold))
                .tracking(2.4)
                .foregroundStyle(AppTheme.gold)
            Text("角色与品牌合作")
                .font(.system(.title3, design: .serif))
                .accessibilityAddTraits(.isHeader)
            CollaborationContactButton {
                Label("发送合作邀约", systemImage: "arrow.up.right")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 22)
                    .frame(minHeight: 44)
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
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(minWidth: 44, minHeight: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.18), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
