import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var portfolioStore: PortfolioStore
    @Environment(LocalWeatherStore.self) private var localWeather
    let showPortfolio: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                AppTheme.ink.ignoresSafeArea()
                HeroPager(
                    imageURLs: portfolioStore.heroImages,
                    localWeather: localWeather,
                    showPortfolio: showPortfolio
                )
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            localWeather.refreshIfAuthorized()
        }
    }
}

private struct HeroPager: View {
    let imageURLs: [URL]
    let localWeather: LocalWeatherStore
    let showPortfolio: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = 0
    @State private var isVisible = false

    private var slides: [URL] {
        imageURLs.isEmpty ? ContentCatalog.heroImages : imageURLs
    }

    private var shouldAutoAdvance: Bool {
        isVisible
            && scenePhase == .active
            && !reduceMotion
            && !voiceOverEnabled
            && slides.count > 1
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

                heroOverlay(in: proxy)
            }
        }
        .onAppear {
            isVisible = true
        }
        .onDisappear { isVisible = false }
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

    @ViewBuilder
    private func heroOverlay(in proxy: GeometryProxy) -> some View {
        let usesCompactLayout = proxy.size.width > proxy.size.height
            || proxy.size.height < 620
            || dynamicTypeSize.isAccessibilitySize
        let topPadding = max(
            18,
            AppWindowMetrics.topInsetForLayout(measured: proxy.safeAreaInsets.top) + 2
        )

        Group {
            if usesCompactLayout {
                compactHeroOverlay(availableWidth: proxy.size.width)
            } else {
                regularHeroOverlay(availableWidth: proxy.size.width)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, topPadding)
        .padding(.bottom, usesCompactLayout ? 16 : 32)
    }

    private func regularHeroOverlay(availableWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            weatherRow(availableWidth: availableWidth)

            Spacer(minLength: 18)

            heroTitle(font: .system(.largeTitle, design: .serif), multiline: true)

            heroSubtitle
                .padding(.top, 15)

            HStack(spacing: 14) {
                portfolioButton
                pageIndicator
            }
            .padding(.top, 26)
        }
    }

    private func compactHeroOverlay(availableWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            weatherRow(availableWidth: availableWidth)

            Spacer(minLength: 8)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 18) {
                    compactHeroCopy
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .trailing, spacing: 12) {
                        portfolioButton
                        pageIndicator
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                VStack(alignment: .leading, spacing: 12) {
                    compactHeroCopy
                    HStack(spacing: 14) {
                        portfolioButton
                        pageIndicator
                    }
                }
            }
        }
    }

    private var compactHeroCopy: some View {
        VStack(alignment: .leading, spacing: dynamicTypeSize.isAccessibilitySize ? 0 : 8) {
            heroTitle(font: .system(.title, design: .serif), multiline: false)

            if !dynamicTypeSize.isAccessibilitySize {
                heroSubtitle
            }
        }
    }

    private func heroTitle(font: Font, multiline: Bool) -> some View {
        Text(multiline ? "镜头之内，\n自有叙事。" : "镜头之内，自有叙事。")
            .font(font)
            .lineSpacing(multiline ? 4 : 2)
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private var heroSubtitle: some View {
        Text("短剧演员 · 模特 · 视频创作者")
            .font(.footnote.weight(.medium))
            .tracking(0.9)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.65), radius: 3, y: 1)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var portfolioButton: some View {
        Button(action: showPortfolio) {
            HStack(spacing: 10) {
                Text("查看作品")
                Image(systemName: "arrow.down.right")
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 20)
            .frame(minHeight: 44)
            .background(.white)
            .foregroundStyle(.black)
            .clipShape(Capsule())
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityIdentifier("home-open-portfolio")
    }

    private func weatherRow(availableWidth: CGFloat) -> some View {
        HStack {
            Spacer(minLength: 0)
            weatherButton
                .frame(
                    maxWidth: min(max(availableWidth - 44, 148), 360),
                    alignment: .trailing
                )
        }
        .foregroundStyle(.white)
    }

    private var weatherButton: some View {
        Button { openWeatherOrSettings() } label: {
            HStack(spacing: 6) {
                weatherStatusIcon
                    .fixedSize()
                Text(
                    "\(WeatherPresentation.conciseLocationText(localWeather.locationText))"
                        + " · \(localWeather.weatherText)"
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.black, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.30), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.20), radius: 6, y: 2)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            // VoiceOver receives the complete button summary below. Hiding the
            // visual fragments avoids exposing location and condition as two
            // competing accessibility nodes while ViewThatFits changes layout.
            .accessibilityHidden(true)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.22),
                value: localWeather.locationText
            )
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.22),
                value: localWeather.weatherText
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("home-weather")
        .accessibilityLabel(localWeather.accessibilitySummary)
        .accessibilityHint(localWeather.needsSettings ? "打开系统设置" : "更新位置与天气")
    }

    private var pageIndicator: some View {
        HStack(spacing: 7) {
            ForEach(slides.indices, id: \.self) { index in
                Capsule()
                    .fill(index == selection ? AppTheme.warmWhite : .white.opacity(0.35))
                    .frame(width: index == selection ? 18 : 5, height: 5)
                    .animation(reduceMotion ? nil : .easeInOut, value: selection)
            }
        }
        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("首页照片")
        .accessibilityValue("第 \(selection + 1) 张，共 \(slides.count) 张")
        .accessibilityHint(slides.count > 1 ? "上下轻扫切换照片" : "")
        .accessibilityAdjustableAction { direction in
            guard slides.count > 1 else { return }
            switch direction {
            case .increment:
                changeSelection(by: 1)
            case .decrement:
                changeSelection(by: -1)
            @unknown default:
                break
            }
        }
    }

    private func changeSelection(by offset: Int) {
        guard !slides.isEmpty else { return }
        let nextSelection = (selection + offset + slides.count) % slides.count
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            selection = nextSelection
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
