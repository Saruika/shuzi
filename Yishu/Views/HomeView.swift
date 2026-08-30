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
        .ignoresSafeArea(.container, edges: .top)
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
    @ScaledMetric(relativeTo: .largeTitle) private var scaledTitleSize: CGFloat = 42
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
                        HeroSlideImage(
                            url: slides[index],
                            fallbackName: ContentCatalog.heroAssetName(at: index),
                            loadsRemoteImage: abs(index - selection) <= 1
                        )
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                            .accessibilityHidden(true)
                            .tag(index)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .tabViewStyle(.page(indexDisplayMode: .never))
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [.black, .black.opacity(0.62), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 132)
                    .allowsHitTesting(false)
                }

                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.55),
                        .init(color: AppTheme.ink.opacity(0.95), location: 1)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Spacer()
                        Button { openWeatherOrSettings() } label: {
                            HStack(spacing: 6) {
                                weatherStatusIcon
                                    .fixedSize()
                                Text(WeatherPresentation.conciseLocationText(localWeather.locationText))
                                    .layoutPriority(2)
                                Text("·")
                                    .foregroundStyle(.white.opacity(0.58))
                                Text(localWeather.weatherText)
                                    .layoutPriority(1)
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.94))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(.black.opacity(0.42), in: Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(.white.opacity(0.20), lineWidth: 0.5)
                            }
                            .shadow(color: .black.opacity(0.20), radius: 6, y: 2)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                            .animation(.easeInOut(duration: 0.22), value: localWeather.locationText)
                            .animation(.easeInOut(duration: 0.22), value: localWeather.weatherText)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home-weather")
                        .accessibilityLabel(localWeather.accessibilitySummary)
                        .accessibilityHint(localWeather.needsSettings ? "打开系统设置" : "更新位置与天气")
                    }
                    .foregroundStyle(.white)

                    Spacer()

                    Text("镜头之内，\n自有叙事。")
                        .font(.editorial(min(scaledTitleSize, 54)))
                        .lineSpacing(4)
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.82)

                    Text("短剧演员 · 模特 · 视频创作者")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(0.9)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
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
                        .accessibilityIdentifier("home-open-portfolio")

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
                .padding(.top, max(18, AppWindowMetrics.topInsetForLayout + 2))
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
            let selectedURL = oldSlides.indices.contains(selection) ? oldSlides[selection] : nil
            selection = selectedURL.flatMap(newSlides.firstIndex(of:))
                ?? min(selection, max(0, newSlides.count - 1))
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

    @ViewBuilder
    private var weatherStatusIcon: some View {
        if localWeather.phase == .locating || localWeather.phase == .loading {
            ProgressView()
                .controlSize(.mini)
                .tint(.white)
        } else {
            Image(systemName: localWeather.symbolName)
        }
    }
}

private struct HeroSlideImage: View {
    let url: URL
    let fallbackName: String?
    let loadsRemoteImage: Bool

    var body: some View {
        GeometryReader { proxy in
            if loadsRemoteImage {
                DownsampledAsyncImage(
                    url: url,
                    targetSize: proxy.size,
                    maximumPixelSize: 1_800
                ) { phase in
                    switch phase {
                    case .empty:
                        fallback
                            .overlay(alignment: .center) {
                                if fallbackName == nil {
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
        .clipped()
    }

    @ViewBuilder
    private var fallback: some View {
        if let fallbackName {
            Image(fallbackName)
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
