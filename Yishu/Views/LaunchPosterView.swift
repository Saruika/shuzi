import SwiftUI

struct LaunchPosterView: View {
    let poster: LaunchPosterContent
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var remoteImageIsVisible = false

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                Image("LaunchPosterFallback")
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                DownsampledAsyncImage(
                    url: poster.imageURL,
                    targetSize: proxy.size,
                    maximumPixelSize: 1_800
                ) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                            .opacity(remoteImageIsVisible ? 1 : 0)
                            .onAppear {
                                if reduceMotion {
                                    remoteImageIsVisible = true
                                } else {
                                    withAnimation(.easeOut(duration: 0.3)) {
                                        remoteImageIsVisible = true
                                    }
                                }
                            }
                    }
                }
            }

            LinearGradient(
                colors: [.black.opacity(0.18), .clear, AppTheme.ink.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("易 姝")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(4)
                        .foregroundStyle(AppTheme.gold)
                    Spacer()
                    Button("跳过", action: dismiss)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.28), in: Capsule())
                        .accessibilityHint("立即进入首页")
                }

                Spacer()

                Text(poster.eyebrow)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(3)
                    .foregroundStyle(AppTheme.gold)
                Text(poster.title)
                    .font(.editorial(44))
                    .foregroundStyle(.white)
                    .padding(.top, 9)
                Text(poster.subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.76))
                    .padding(.top, 10)

                Capsule()
                    .fill(.white.opacity(0.82))
                    .frame(width: 34, height: 2)
                    .padding(.top, 24)
            }
            .padding(.horizontal, 22)
            .padding(.top, max(12, AppWindowMetrics.topInsetForLayout + 12))
            .padding(.bottom, max(20, AppWindowMetrics.bottomInsetForLayout + 20))
        }
        .ignoresSafeArea()
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .background(AppTheme.ink.ignoresSafeArea())
        .task(id: poster.id) {
            do {
                let duration = min(max(poster.displaySeconds, 1.5), 5)
                try await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                dismiss()
            } catch { }
        }
    }
}
