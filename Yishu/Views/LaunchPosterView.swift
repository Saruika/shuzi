import SwiftUI
import UIKit

struct LaunchPosterView: View {
    let poster: LaunchPosterContent
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControlEnabled
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var remoteImageIsVisible = false
    @State private var artworkScale: CGFloat = 1.035
    @State private var copyIsVisible = false

    private var pausesAutomaticDismissal: Bool {
        voiceOverEnabled || switchControlEnabled || dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        GeometryReader { proxy in
            let topInset = AppWindowMetrics.topInsetForLayout(
                measured: proxy.safeAreaInsets.top
            )
            let bottomInset = AppWindowMetrics.bottomInsetForLayout(
                measured: proxy.safeAreaInsets.bottom
            )
            let horizontalSafeArea = LaunchPosterWindowSafeArea.horizontalInsets(
                measured: proxy.safeAreaInsets
            )
            let leadingInset = max(20, horizontalSafeArea.leading + 16)
            let trailingInset = max(20, horizontalSafeArea.trailing + 16)
            let topControlInset = topInset + 10
            let bottomContentInset = bottomInset + (proxy.size.width > proxy.size.height ? 14 : 24)
            let copyTopInset = topControlInset + 56
            let copyAvailableHeight = max(
                80,
                proxy.size.height - copyTopInset - bottomContentInset
            )
            let needsScrollableCopy = proxy.size.width > proxy.size.height
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

                DownsampledAsyncImage(
                    url: poster.imageURL,
                    targetSize: proxy.size,
                    maximumPixelSize: 1_800
                ) { phase in
                    if case .success(let image) = phase {
                        launchArtwork(image, in: proxy.size)
                            .scaleEffect(artworkScale)
                            .opacity(remoteImageIsVisible ? 1 : 0)
                            .onAppear {
                                if reduceMotion {
                                    remoteImageIsVisible = true
                                    artworkScale = 1
                                    copyIsVisible = true
                                } else {
                                    withAnimation(.easeOut(duration: 0.45)) {
                                        remoteImageIsVisible = true
                                    }
                                    withAnimation(.linear(duration: min(max(poster.displaySeconds, 1.5), 5) + 0.6)) {
                                        artworkScale = 1
                                    }
                                    withAnimation(.easeOut(duration: 0.55).delay(0.12)) {
                                        copyIsVisible = true
                                    }
                                }
                            }
                    } else if case .empty = phase {
                        ProgressView()
                            .tint(AppTheme.gold)
                            .frame(width: proxy.size.width, height: proxy.size.height)
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

                statusBarScrim(topInset: topInset, canvasHeight: proxy.size.height)

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

                Button(action: dismiss) {
                    Text("跳过")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(minWidth: 44, minHeight: 44)
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
                .accessibilityHint("立即进入首页")
                .accessibilityIdentifier("launch-poster-skip")
            }
        }
        .ignoresSafeArea()
        .background(AppTheme.ink.ignoresSafeArea())
        .task(
            id: LaunchPosterDismissTaskID(
                imageURL: poster.imageURL,
                imageIsVisible: remoteImageIsVisible,
                pausesAutomaticDismissal: pausesAutomaticDismissal
            )
        ) {
            guard !pausesAutomaticDismissal else { return }
            do {
                let duration = remoteImageIsVisible
                    ? min(max(poster.displaySeconds, 1.5), 5)
                    : 10
                try await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled,
                      !pausesAutomaticDismissal else { return }
                dismiss()
            } catch { }
        }
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
            HStack(spacing: compact ? 8 : 10) {
                Capsule()
                    .fill(AppTheme.gold)
                    .frame(width: compact ? 18 : 26, height: 1.5)

                Text(poster.eyebrow)
                    .font(compact ? .caption2.weight(.bold) : .caption.weight(.bold))
                    .tracking(compact ? 2.2 : 3)
                    .foregroundStyle(AppTheme.gold)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
private enum LaunchPosterWindowSafeArea {
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
