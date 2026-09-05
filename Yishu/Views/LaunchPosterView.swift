import SwiftUI
import UIKit

struct LaunchPosterView: View {
    let poster: LaunchPosterContent
    let dismiss: () -> Void
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControlEnabled
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var artworkIsVisible = false

    private var pausesAutomaticDismissal: Bool {
        voiceOverEnabled || switchControlEnabled || dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        GeometryReader { proxy in
            LaunchPosterCanvas(
                poster: poster,
                size: proxy.size,
                safeAreaInsets: LaunchPosterWindowSafeArea.resolvedInsets(measured: proxy.safeAreaInsets),
                artworkIsVisible: $artworkIsVisible,
                dismiss: dismiss
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .background(AppTheme.ink.ignoresSafeArea())
        .task(
            id: LaunchPosterDismissTaskID(
                imageURL: poster.imageURL,
                imageIsVisible: artworkIsVisible,
                pausesAutomaticDismissal: pausesAutomaticDismissal
            )
        ) {
            guard !pausesAutomaticDismissal else { return }
            do {
                let duration = artworkIsVisible
                    ? min(max(poster.displaySeconds, 1.5), 5)
                    : 10
                try await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled,
                      !pausesAutomaticDismissal else { return }
                dismiss()
            } catch { }
        }
    }
}

/// One presentation surface for the real launch and the administrator's scaled
/// preview. Timing belongs to LaunchPosterView, never to this reusable canvas.
struct LaunchPosterCanvas: View {
    let poster: LaunchPosterContent
    let size: CGSize
    let safeAreaInsets: EdgeInsets
    @Binding var artworkIsVisible: Bool
    let dismiss: () -> Void
    var imageTargetSize: CGSize? = nil
    var isPreview = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var remoteImageIsVisible = false
    // Copy must remain visible even while the remote image is loading.
    @State private var copyIsVisible = true

    var body: some View {
        let topInset = safeAreaInsets.top
        let bottomInset = safeAreaInsets.bottom
        let horizontalSafeArea = (leading: safeAreaInsets.leading, trailing: safeAreaInsets.trailing)
        let leadingInset = max(20, horizontalSafeArea.leading + 16)
        let trailingInset = max(20, horizontalSafeArea.trailing + 16)
        let topControlInset = topInset + 10
        let bottomContentInset = bottomInset + (size.width > size.height ? 14 : 24)
        let copyTopInset = topControlInset + 56
        let copyAvailableHeight = max(
            80,
            size.height - copyTopInset - bottomContentInset
        )
        let needsScrollableCopy = size.width > size.height
            || dynamicTypeSize.isAccessibilitySize

        ZStack {
            AppTheme.ink
                .overlay {
                    LinearGradient(
                        colors: [.white.opacity(0.025), .clear, AppTheme.gold.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
            }

            ZStack {
                launchPlaceholder(in: size)

                DownsampledAsyncImage(
                    url: poster.imageURL,
                    targetSize: imageTargetSize ?? size,
                    maximumPixelSize: 2_880,
                    showsRetryButton: false
                ) { phase in
                    if case .success(let image) = phase {
                        launchArtwork(image, in: size)
                            .opacity(remoteImageIsVisible ? 1 : 0)
                            .onAppear {
                                revealArtworkIfNeeded()
                                if reduceMotion {
                                    remoteImageIsVisible = true
                                } else {
                                    withAnimation(.easeOut(duration: 0.45)) {
                                        remoteImageIsVisible = true
                                    }
                                }
                            }
                    }
                }
            }

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.5),
                    .init(color: AppTheme.ink.opacity(0.94), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            statusBarScrim(topInset: topInset, canvasHeight: size.height)

            if needsScrollableCopy {
                ScrollView(.vertical) {
                    LaunchPosterTextBlock(poster: poster)
                        .frame(minHeight: copyAvailableHeight, alignment: .bottom)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .padding(.top, copyTopInset)
                .padding(.bottom, bottomContentInset)
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
                .opacity(copyIsVisible ? 1 : 0)
                .offset(y: copyIsVisible ? 0 : 12)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: copyTopInset)

                    LaunchPosterTextBlock(poster: poster)
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
                .padding(.bottom, bottomContentInset)
                .opacity(copyIsVisible ? 1 : 0)
                .offset(y: copyIsVisible ? 0 : 12)
            }

            Group {
                if isPreview {
                    skipLabel
                } else {
                    Button(action: dismiss) { skipLabel }
                }
            }
            .foregroundStyle(.white)
            .background(.black.opacity(0.58), in: Capsule())
            .overlay {
                Capsule().stroke(.white.opacity(0.24), lineWidth: 0.5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, topControlInset)
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
            .accessibilityHint(isPreview ? "" : "立即进入首页")
            .accessibilityIdentifier(isPreview ? "admin-launch-poster-skip-decoration" : "launch-poster-skip")
            .accessibilityHidden(isPreview)
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("launch-poster-canvas")

    }

    private var skipLabel: some View {
        Text("跳过")
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minWidth: 44, minHeight: 44)
    }

    private func revealArtworkIfNeeded() {
        guard !artworkIsVisible else { return }
        if reduceMotion {
            artworkIsVisible = true
            copyIsVisible = true
        } else {
            withAnimation(.easeOut(duration: 0.45)) {
                artworkIsVisible = true
            }
            withAnimation(.easeOut(duration: 0.55).delay(0.12)) {
                copyIsVisible = true
            }
        }
    }

    private func launchPlaceholder(in size: CGSize) -> some View {
        ZStack {
            AppTheme.ink
            RadialGradient(
                colors: [AppTheme.gold.opacity(0.16), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: max(size.width, size.height) * 0.78
            )
            LinearGradient(
                colors: [.white.opacity(0.035), .clear, AppTheme.gold.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            ProgressView()
                .controlSize(.small)
                .tint(AppTheme.gold)
                .accessibilityLabel("正在安全加载开屏图片")
                .accessibilityIdentifier("launch-poster-loading")
        }
        .frame(width: size.width, height: size.height)
    }

    private func statusBarScrim(topInset: CGFloat, canvasHeight: CGFloat) -> some View {
        let protectedHeight = max(topInset + 42, min(canvasHeight * 0.2, 150))
        let safeAreaStop = min(max((topInset + 8) / protectedHeight, 0.24), 0.7)

        return LinearGradient(
            stops: [
                .init(color: .black.opacity(0.88), location: 0),
                .init(color: .black.opacity(0.78), location: safeAreaStop),
                .init(color: .black.opacity(0.34), location: 0.76),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: protectedHeight)
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func launchArtwork(_ image: Image, in size: CGSize) -> some View {
        if size.width / max(size.height, 1) > 0.64 {
            ZStack {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .blur(radius: 34)
                    .overlay(AppTheme.ink.opacity(0.42))

                image
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        } else {
            image
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
        }
    }
}

struct LaunchPosterTextBlock: View {
    let poster: LaunchPosterContent
    var compact = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var titleFont: Font {
        if compact { return .title2.weight(.semibold) }
        return horizontalSizeClass == .regular
            ? .largeTitle.weight(.semibold)
            : .title.weight(.semibold)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 11) {
            Text(poster.eyebrow)
                .font(compact ? .caption2.weight(.bold) : .caption.weight(.bold))
                .tracking(compact ? 2.2 : 3)
                .foregroundStyle(AppTheme.gold)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: false, vertical: true)

            Text(poster.title)
                .font(titleFont)
                .tracking(0.6)
                .foregroundStyle(.white)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : (compact ? 2 : 3))
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.34), radius: 12, y: 3)

            Text(poster.subtitle)
                .font(compact ? .caption.weight(.medium) : .subheadline.weight(.medium))
                .tracking(compact ? 0.2 : 0.5)
                .foregroundStyle(.white.opacity(0.84))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
        }
        .frame(maxWidth: compact ? .infinity : 560, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("launch-poster-copy")
    }
}

private struct LaunchPosterDismissTaskID: Hashable {
    let imageURL: URL
    let imageIsVisible: Bool
    let pausesAutomaticDismissal: Bool
}

@MainActor
enum LaunchPosterWindowSafeArea {
    static var windowSize: CGSize? { activeWindow?.bounds.size }

    static func resolvedInsets(measured: EdgeInsets = EdgeInsets()) -> EdgeInsets {
        let horizontal = horizontalInsets(measured: measured)
        return EdgeInsets(
            top: AppWindowMetrics.topInsetForLayout(measured: measured.top),
            leading: horizontal.leading,
            bottom: AppWindowMetrics.bottomInsetForLayout(measured: measured.bottom),
            trailing: horizontal.trailing
        )
    }

    static func horizontalInsets(measured: EdgeInsets) -> (leading: CGFloat, trailing: CGFloat) {
        let fallback = activeWindow?.safeAreaInsets
        return (
            measured.leading > 0 ? measured.leading : fallback?.left ?? 0,
            measured.trailing > 0 ? measured.trailing : fallback?.right ?? 0
        )
    }

    private static var activeWindow: UIWindow? {
        let foregroundScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter {
                $0.activationState == .foregroundActive
                    || $0.activationState == .foregroundInactive
            }

        return foregroundScenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? foregroundScenes
                .flatMap(\.windows)
                .first(where: { !$0.isHidden && $0.alpha > 0 })
    }
}
