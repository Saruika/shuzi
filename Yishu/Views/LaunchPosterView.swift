import SwiftUI

struct LaunchPosterView: View {
    let poster: LaunchPosterContent
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var remoteImageIsVisible = false
    @State private var artworkScale: CGFloat = 1.035
    @State private var copyIsVisible = false

    var body: some View {
        ZStack {
            GeometryReader { proxy in
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
                    }
                }
            }

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.5), location: 0),
                    .init(color: .clear, location: 0.26),
                    .init(color: .clear, location: 0.5),
                    .init(color: AppTheme.ink.opacity(0.94), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    Button(action: dismiss) {
                        Text("跳过")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .background(.black.opacity(0.32), in: Capsule())
                    .overlay {
                        Capsule().stroke(.white.opacity(0.14), lineWidth: 0.5)
                    }
                    .accessibilityHint("立即进入首页")
                }

                Spacer()

                LaunchPosterTextBlock(poster: poster)
                    .opacity(copyIsVisible ? 1 : 0)
                    .offset(y: copyIsVisible ? 0 : 12)
            }
            .padding(.horizontal, 22)
            .padding(.top, max(12, AppWindowMetrics.topInsetForLayout + 12))
            .padding(.bottom, max(24, AppWindowMetrics.bottomInsetForLayout + 24))
        }
        .ignoresSafeArea()
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .background(AppTheme.ink.ignoresSafeArea())
        .task(id: remoteImageIsVisible) {
            guard remoteImageIsVisible else { return }
            do {
                let duration = min(max(poster.displaySeconds, 1.5), 5)
                try await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                dismiss()
            } catch { }
        }
        .task(id: poster.imageURL) {
            do {
                try await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, !remoteImageIsVisible else { return }
                dismiss()
            } catch { }
        }
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var titleSize: CGFloat {
        if compact { return 30 }
        return horizontalSizeClass == .regular ? 48 : 40
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 11) {
            HStack(spacing: compact ? 8 : 10) {
                Capsule()
                    .fill(AppTheme.gold)
                    .frame(width: compact ? 18 : 26, height: 1.5)

                Text(poster.eyebrow)
                    .font(.system(size: compact ? 8 : 10, weight: .bold))
                    .tracking(compact ? 2.2 : 3)
                    .foregroundStyle(AppTheme.gold)
                    .lineLimit(1)
            }

            Text(poster.title)
                .font(.system(size: titleSize, weight: .semibold, design: .default))
                .tracking(0.6)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .shadow(color: .black.opacity(0.34), radius: 12, y: 3)

            Text(poster.subtitle)
                .font(.system(size: compact ? 11 : 15, weight: .medium))
                .tracking(compact ? 0.2 : 0.5)
                .foregroundStyle(.white.opacity(0.84))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
        }
        .frame(maxWidth: compact ? .infinity : 560, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
