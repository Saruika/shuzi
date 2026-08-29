import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var portfolioStore: PortfolioStore
    @EnvironmentObject private var localWeather: LocalWeatherStore
    let showPortfolio: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                AppTheme.ink.ignoresSafeArea()
                HeroPager(imageURLs: portfolioStore.heroImages, showPortfolio: showPortfolio)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { localWeather.refreshIfAuthorized() }
    }
}

private struct HeroPager: View {
    let imageURLs: [URL]
    let showPortfolio: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var localWeather: LocalWeatherStore
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 42
    @State private var selection = 0
    @State private var isVisible = false

    private var slides: [URL] {
        imageURLs.isEmpty ? ContentCatalog.heroImages : imageURLs
    }

    private var shouldAutoAdvance: Bool {
        isVisible && scenePhase == .active && !reduceMotion && slides.count > 1
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                TabView(selection: $selection) {
                    ForEach(slides.indices, id: \.self) { index in
                        HeroSlideImage(url: slides[index])
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                            .accessibilityHidden(true)
                            .tag(index)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .tabViewStyle(.page(indexDisplayMode: .never))

                LinearGradient(
                    colors: [.black.opacity(0.08), .clear, AppTheme.ink.opacity(0.95)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Spacer()
                        Button { openWeatherOrSettings() } label: {
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(localWeather.locationText)
                                    .font(.system(size: 10, weight: .semibold))
                                HStack(spacing: 5) {
                                    if localWeather.phase == .locating || localWeather.phase == .loading {
                                        ProgressView()
                                            .controlSize(.mini)
                                            .tint(.white.opacity(0.72))
                                    } else {
                                        Image(systemName: localWeather.symbolName)
                                            .font(.system(size: 9, weight: .medium))
                                    }
                                    Text(localWeather.weatherText)
                                        .font(.system(size: 9, weight: .medium))
                                }
                                .foregroundStyle(.white.opacity(0.72))
                            }
                            .lineLimit(1)
                            .frame(maxWidth: 120, alignment: .trailing)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(localWeather.accessibilitySummary)
                        .accessibilityHint(localWeather.needsSettings ? "打开系统设置" : "更新位置与天气")
                    }
                    .foregroundStyle(.white)

                    Spacer()

                    Text("镜头之内，\n自有叙事。")
                        .font(.editorial(titleSize))
                        .lineSpacing(4)
                        .foregroundStyle(.white)

                    Text("短剧演员 · 模特 · 视频创作者")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(0.9)
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(.top, 15)

                    HStack(spacing: 14) {
                        Button(action: showPortfolio) {
                            HStack(spacing: 10) {
                                Text("查看作品")
                                Image(systemName: "arrow.down.right")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 13)
                            .background(.white)
                            .foregroundStyle(.black)
                            .clipShape(Capsule())
                        }

                        HStack(spacing: 7) {
                            ForEach(slides.indices, id: \.self) { index in
                                Capsule()
                                    .fill(index == selection ? AppTheme.warmWhite : .white.opacity(0.35))
                                    .frame(width: index == selection ? 18 : 5, height: 5)
                                    .animation(reduceMotion ? nil : .easeInOut, value: selection)
                            }
                        }
                    }
                    .padding(.top, 26)
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 32)
            }
        }
        .onAppear {
            selection = 0
            isVisible = true
        }
        .onDisappear { isVisible = false }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, isVisible {
                selection = 0
            }
        }
        .task(id: shouldAutoAdvance) {
            guard shouldAutoAdvance else { return }
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(5))
                    guard shouldAutoAdvance else { return }
                    withAnimation(.easeInOut(duration: 0.65)) {
                        selection = (selection + 1) % slides.count
                    }
                }
            } catch { }
        }
        .onChange(of: slides) { oldSlides, newSlides in
            guard oldSlides != newSlides else { return }
            selection = 0
        }
    }

    private func openWeatherOrSettings() {
        if localWeather.needsSettings,
           let settingsURL = URL(string: UIApplication.openSettingsURLString) {
            openURL(settingsURL)
        } else {
            localWeather.activate()
        }
    }
}

private struct HeroSlideImage: View {
    let url: URL

    private var bundledFallback: String? {
        guard let index = ContentCatalog.heroImages.firstIndex(of: url) else { return nil }
        let names = ["HeroOne", "HeroTwo", "HeroThree"]
        guard names.indices.contains(index) else { return nil }
        return names[index]
    }

    var body: some View {
        AsyncImage(
            url: url,
            transaction: Transaction(animation: .easeOut(duration: 0.35))
        ) { phase in
            switch phase {
            case .empty:
                fallback
                    .overlay(alignment: .center) {
                        if bundledFallback == nil {
                            ProgressView().tint(AppTheme.gold)
                        }
                    }
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            case .failure:
                fallback
            @unknown default:
                fallback
            }
        }
    }

    @ViewBuilder
    private var fallback: some View {
        if let bundledFallback {
            Image(bundledFallback)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                AppTheme.elevatedInk
                LinearGradient(
                    colors: [.white.opacity(0.035), .clear, AppTheme.gold.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }
}
