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
    @State private var isWeatherDetailsPresented = false

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
        .sheet(isPresented: $isWeatherDetailsPresented) {
            WeatherAttributionSheet(localWeather: localWeather)
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
                compactHeroOverlay
            } else {
                regularHeroOverlay
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, topPadding)
        .padding(.bottom, usesCompactLayout ? 16 : 32)
    }

    private var regularHeroOverlay: some View {
        VStack(alignment: .leading, spacing: 0) {
            weatherRow

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

    private var compactHeroOverlay: some View {
        VStack(alignment: .leading, spacing: 0) {
            weatherRow

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

    private var weatherRow: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            if localWeather.phase == .ready {
                weatherAttributionControl
            }
            weatherButton
        }
        .foregroundStyle(.white)
    }

    private var weatherAttributionControl: some View {
        Button {
            isWeatherDetailsPresented = true
            localWeather.refreshAttributionIfNeeded()
        } label: {
            HStack(spacing: 3) {
                AsyncImage(url: localWeather.attributionMarkURL) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFit()
                    } else {
                        Text(localWeather.weatherProviderName)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .allowsTightening(true)
                    }
                }
                .frame(width: 72, height: 18)

                Image(systemName: "info.circle")
                    .font(.caption2.weight(.semibold))
            }
            .frame(width: 82, height: 18)
            .foregroundStyle(.white.opacity(0.88))
            .shadow(color: .black.opacity(0.72), radius: 2, y: 1)
            .frame(minWidth: 88, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityLabel("Apple Weather 数据来源与许可")
        .accessibilityHint("打开天气详情")
        .accessibilityIdentifier("home-weather-attribution-control")
    }

    private var weatherButton: some View {
        Button { openWeatherOrSettings() } label: {
            weatherSummary
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
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
                // VoiceOver receives the complete button summary below. Hiding
                // the visual fragments avoids duplicate accessibility nodes.
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
        // The hero is a compact photographic overlay. Keep it readable when
        // the system uses accessibility sizes without allowing this one
        // capsule to obscure the portrait; the details sheet and VoiceOver
        // continue to expose the complete, uncapped weather information.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityIdentifier("home-weather")
        .accessibilityLabel(localWeather.accessibilitySummary)
        .accessibilityHint(weatherAccessibilityHint)
    }

    private var weatherSummary: some View {
        HStack(spacing: 6) {
            weatherStatusIcon
                .fixedSize()
            Text(
                WeatherPresentation.compactSummary(
                    location: localWeather.locationText,
                    weather: localWeather.weatherText
                )
            )
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .allowsTightening(true)
        }
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
        if localWeather.phase == .ready {
            isWeatherDetailsPresented = true
            localWeather.refreshAttributionIfNeeded()
        } else if localWeather.needsSettings,
           let settingsURL = URL(string: UIApplication.openSettingsURLString) {
            openURL(settingsURL)
        } else {
            localWeather.activate()
        }
    }

    private var weatherAccessibilityHint: String {
        if localWeather.phase == .ready {
            return "打开天气详情、Apple Weather 数据来源与许可"
        }
        return localWeather.needsSettings ? "打开系统设置" : "更新位置与天气"
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

private struct WeatherAttributionSheet: View {
    let localWeather: LocalWeatherStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("当地天气")
                            .font(.title2.weight(.semibold))
                            .accessibilityIdentifier("home-weather-attribution-heading")
                            .accessibilityAddTraits(.isHeader)
                        Text(
                            "\(WeatherPresentation.conciseLocationText(localWeather.locationText))"
                                + " · \(localWeather.weatherText)"
                        )
                        .font(.body)
                        .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        AsyncImage(url: localWeather.attributionMarkURL) { phase in
                            if case .success(let image) = phase {
                                image
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 132, height: 34, alignment: .leading)
                            } else {
                                Text(localWeather.weatherProviderName)
                                    .font(.headline.weight(.semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Apple Weather")
                        .accessibilityIdentifier("home-weather-provider")

                        Text("天气数据由 Apple Weather 提供。可查看数据来源、版权与许可信息。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Link(destination: localWeather.attributionLegalURL) {
                            HStack(spacing: 10) {
                                Text("Apple Weather 数据来源与许可")
                                Spacer(minLength: 12)
                                Image(systemName: "arrow.up.right")
                            }
                            .font(.body.weight(.semibold))
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home-weather-legal-link")
                        .accessibilityHint("打开 Apple Weather 数据来源与许可页")
                    }
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                }
                .padding(20)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("天气详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("home-weather-details-close")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCompactAdaptation(.sheet)
        .task {
            localWeather.refreshAttributionIfNeeded()
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
