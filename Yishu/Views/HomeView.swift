import SwiftUI
import UIKit

enum HomeHeroPresentation: String, Equatable {
    case fill
    case fit
}

enum HomeHeroRenderPolicy {
    static func presentation(
        for viewport: CGSize,
        idiom: UIUserInterfaceIdiom
    ) -> HomeHeroPresentation {
        idiom == .pad && viewport.width > viewport.height ? .fit : .fill
    }

    static func fittedSize(sourceSize: CGSize, in viewport: CGSize) -> CGSize {
        guard sourceSize.width > 0,
              sourceSize.height > 0,
              viewport.width > 0,
              viewport.height > 0 else { return .zero }
        let scale = min(
            viewport.width / sourceSize.width,
            viewport.height / sourceSize.height
        )
        return CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
    }

    static func shouldLoadRemoteImage(
        at index: Int,
        selection: Int,
        count: Int,
        presentation: HomeHeroPresentation = .fill
    ) -> Bool {
        guard count > 0,
              (0..<count).contains(index),
              (0..<count).contains(selection) else { return false }
        // A landscape iPad shows the whole portrait photograph, so a blank
        // neighbouring page is especially conspicuous. The hero is capped at
        // five images; warming this small, bounded set in volatile memory
        // keeps every swipe continuous without persisting protected media.
        if presentation == .fit { return true }
        let directDistance = abs(index - selection)
        let circularDistance = min(directDistance, count - directDistance)
        return circularDistance <= 1
    }

    static func prefetchIndices(
        selection: Int,
        count: Int,
        presentation: HomeHeroPresentation = .fill
    ) -> [Int] {
        guard count > 0, (0..<count).contains(selection) else { return [] }
        if presentation == .fit { return Array(0..<count) }
        return Array(Set([
            (selection - 1 + count) % count,
            selection,
            (selection + 1) % count,
        ])).sorted()
    }

    static func shouldAnimateTransition(from current: Int, to next: Int, count: Int) -> Bool {
        guard count > 1,
              (0..<count).contains(current),
              (0..<count).contains(next) else { return false }
        return abs(current - next) == 1
    }
}

struct HomeView: View {
    @EnvironmentObject private var portfolioStore: PortfolioStore
    @Environment(LocalWeatherStore.self) private var localWeather
    let showPortfolio: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                MediaTheme.ink.ignoresSafeArea()
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
        .toolbarColorScheme(.dark, for: .tabBar)
        .environment(\.colorScheme, .dark)
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
    @Environment(\.displayScale) private var displayScale
    @State private var selection = HeroPager.visualTestInitialSelection
    @State private var isVisible = false
    @State private var landscapeContinuityImage: UIImage?

    private var slides: [URL] {
        // Keep the adaptive-layout fixture independent from a stale manifest
        // left in the simulator by an earlier UI test. This branch is only
        // reachable from the DEBUG-only visual-test launch argument.
        if holdsRemoteImagesForVisualTesting {
            return ContentCatalog.heroImages
        }
        return imageURLs.isEmpty ? ContentCatalog.heroImages : imageURLs
    }

    private var shouldAutoAdvance: Bool {
        return isVisible
            && scenePhase == .active
            && !reduceMotion
            && !voiceOverEnabled
            && !disablesAutoAdvanceForVisualTesting
            && slides.count > 1
    }

    var body: some View {
        GeometryReader { proxy in
            let presentation = HomeHeroRenderPolicy.presentation(
                for: proxy.size,
                idiom: UIDevice.current.userInterfaceIdiom
            )
            let exposesVisualTestState = exposesHeroStateForVisualTesting

            ZStack(alignment: .bottom) {
                TabView(selection: $selection) {
                    ForEach(slides.indices, id: \.self) { index in
                        let loadsRemoteImage = !holdsRemoteImagesForVisualTesting
                            && HomeHeroRenderPolicy.shouldLoadRemoteImage(
                                at: index,
                                selection: selection,
                                count: slides.count,
                                presentation: presentation
                            )
                        let visualTestIdentifier = exposesVisualTestState
                            && presentation == .fit
                            && index == selection
                            ? "home-hero-actual-fitted-image-\(index)"
                            : nil

                        HeroSlideImage(
                            url: slides[index],
                            loadsRemoteImage: loadsRemoteImage,
                            usesVisualTestArtwork: holdsRemoteImagesForVisualTesting,
                            presentation: presentation,
                            visualTestIdentifier: visualTestIdentifier,
                            continuityImage: presentation == .fit
                                ? landscapeContinuityImage
                                : nil,
                            onImageLoaded: { loadedImage in
                                guard presentation == .fit,
                                      index == selection else { return }
                                landscapeContinuityImage = loadedImage
                            }
                        )
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                            .accessibilityHidden(!exposesVisualTestState || index != selection)
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
                        .init(
                            color: MediaTheme.ink.opacity(presentation == .fit ? 0.68 : 0.95),
                            location: 1
                        )
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                heroOverlay(in: proxy)

                homeHeroVisualTestControls(
                    presentation: presentation
                )
            }
            .task(id: prefetchRequestID(for: proxy.size)) {
                guard !holdsRemoteImagesForVisualTesting else { return }
                await ArtworkImagePrefetcher.prefetch(
                    urls: prefetchURLs(for: presentation),
                    maxPixelSize: min(
                        1_800,
                        max(
                            320,
                            Int(ceil(max(proxy.size.width, proxy.size.height) * displayScale))
                        )
                    )
                )
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
                    setSelection(
                        (selection + 1) % slides.count,
                        animationDuration: 0.65
                    )
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
            weatherButton
        }
        .foregroundStyle(.white)
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
        // capsule to obscure the portrait; VoiceOver continues to expose the
        // complete, uncapped weather summary.
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
                    .fill(index == selection ? MediaTheme.warmWhite : .white.opacity(0.35))
                    .frame(width: index == selection ? 18 : 5, height: 5)
                    .animation(reduceMotion ? nil : .easeInOut, value: selection)
            }
        }
        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("首页照片")
        .accessibilityValue("第 \(selection + 1) 张，共 \(slides.count) 张")
        .accessibilityIdentifier("home-hero-page-indicator")
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
        setSelection(nextSelection, animationDuration: 0.22)
    }

    private func setSelection(_ nextSelection: Int, animationDuration: Double) {
        let shouldAnimate = !reduceMotion
            && HomeHeroRenderPolicy.shouldAnimateTransition(
                from: selection,
                to: nextSelection,
                count: slides.count
            )
        if shouldAnimate {
            withAnimation(.easeInOut(duration: animationDuration)) {
                selection = nextSelection
            }
        } else {
            selection = nextSelection
        }
    }

    private func prefetchURLs(for presentation: HomeHeroPresentation) -> [URL] {
        HomeHeroRenderPolicy.prefetchIndices(
            selection: selection,
            count: slides.count,
            presentation: presentation
        ).map { slides[$0] }
    }

    private func prefetchRequestID(for size: CGSize) -> String {
        let presentation = HomeHeroRenderPolicy.presentation(
            for: size,
            idiom: UIDevice.current.userInterfaceIdiom
        )
        let urls = prefetchURLs(for: presentation)
            .map(\.absoluteString)
            .joined(separator: "|")
        // In fit mode every bounded hero URL is already part of this request.
        // Keeping the current page out of the identity prevents a swipe from
        // cancelling and restarting the same preheat work mid-transition.
        let selectionKey = presentation == .fit ? "all" : String(selection)
        return "\(selectionKey)#\(Int(size.width.rounded()))x\(Int(size.height.rounded()))#\(urls)"
    }

    private var holdsRemoteImagesForVisualTesting: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains(
            "-hold-home-remote-images-for-visual-testing"
        )
#else
        false
#endif
    }

    private var disablesAutoAdvanceForVisualTesting: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains(
            "-disable-home-auto-advance-for-visual-testing"
        )
#else
        false
#endif
    }

    private var exposesHeroStateForVisualTesting: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains(
            "-expose-home-hero-state-for-visual-testing"
        )
#else
        false
#endif
    }

    private static var visualTestInitialSelection: Int {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(
            of: "-home-hero-selection-for-visual-testing"
        ),
            arguments.indices.contains(flag + 1),
            let value = Int(arguments[flag + 1]) else { return 0 }
        return min(
            max(0, value),
            max(0, ContentCatalog.heroImages.count - 1)
        )
#else
        0
#endif
    }

    @ViewBuilder
    private func homeHeroVisualTestControls(
        presentation: HomeHeroPresentation
    ) -> some View {
#if DEBUG
        if exposesHeroStateForVisualTesting {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    presentation == .fit ? "完整显示" : "铺满显示"
                )
                .accessibilityValue("第 \(selection + 1) 张，共 \(slides.count) 张")
                .accessibilityIdentifier("home-hero-visual-state-\(selection)")
                .id("home-hero-visual-state-\(selection)")
                .allowsHitTesting(false)
        }
#endif
    }

    private func openWeatherOrSettings() {
        if localWeather.phase == .ready {
            localWeather.activate()
        } else if localWeather.needsSettings,
           let settingsURL = URL(string: UIApplication.openSettingsURLString) {
            openURL(settingsURL)
        } else {
            localWeather.activate()
        }
    }

    private var weatherAccessibilityHint: String {
        if localWeather.phase == .ready {
            return "刷新当前位置与天气"
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

private struct HeroSlideImage: View {
    let url: URL
    let loadsRemoteImage: Bool
    let usesVisualTestArtwork: Bool
    let presentation: HomeHeroPresentation
    let visualTestIdentifier: String?
    let continuityImage: UIImage?
    let onImageLoaded: (UIImage) -> Void
    @State private var measuredURL: URL?
    @State private var measuredSourceSize: CGSize?

    var body: some View {
        GeometryReader { proxy in
            if usesVisualTestArtwork {
                visualTestComposition(in: proxy.size)
            } else if presentation == .fit {
                fittedComposition(in: proxy.size)
            } else {
                filledComposition(in: proxy.size)
            }
        }
        .clipped()
    }

    @ViewBuilder
    private func visualTestComposition(in size: CGSize) -> some View {
#if DEBUG
        let sourceSize = CGSize(width: 959, height: 1_440)
        if presentation == .fit {
            let fittedSize = HomeHeroRenderPolicy.fittedSize(
                sourceSize: sourceSize,
                in: size
            )
            ZStack {
                visualTestArtwork
                    .frame(width: size.width, height: size.height)
                    .blur(radius: 24, opaque: true)
                    .overlay { Color.black.opacity(0.12) }

                visualTestArtwork
                    .frame(width: fittedSize.width, height: fittedSize.height)

                HomeHeroLayoutProbe(
                    identifier: visualTestIdentifier ?? "",
                    sourceSize: sourceSize
                )
                .frame(width: size.width, height: size.height)
            }
            .frame(width: size.width, height: size.height)
        } else {
            visualTestArtwork
                .frame(width: size.width, height: size.height)
        }
#else
        placeholder
#endif
    }

    private var visualTestArtwork: some View {
        LinearGradient(
            colors: [
                Color(red: 0.72, green: 0.79, blue: 0.70),
                Color(red: 0.88, green: 0.82, blue: 0.64),
                Color(red: 0.30, green: 0.40, blue: 0.34),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    @ViewBuilder
    private func fittedComposition(in size: CGSize) -> some View {
        ZStack {
            fittedBackground(in: size)

            remoteImage(in: size, usesFittedPresentation: true)

#if DEBUG
            if !loadsRemoteImage, let visualTestIdentifier {
                Color.clear
                    .frame(width: size.width, height: size.height)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("完整首页照片布局范围")
                    .accessibilityIdentifier(visualTestIdentifier)
            }
#endif
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder
    private func filledComposition(in size: CGSize) -> some View {
        ZStack {
            placeholder
                .overlay { ProgressView().tint(MediaTheme.gold) }

            remoteImage(in: size, usesFittedPresentation: false)
        }
    }

    @ViewBuilder
    private func remoteImage(
        in size: CGSize,
        usesFittedPresentation: Bool
    ) -> some View {
        if loadsRemoteImage {
            DownsampledAsyncImage(
                url: url,
                targetSize: size,
                maximumPixelSize: 1_800,
                onImageLoaded: { loadedImage in
                    measuredURL = url
                    measuredSourceSize = loadedImage.size
                    onImageLoaded(loadedImage)
                }
            ) { phase in
                switch phase {
                case .success(let image):
                    if usesFittedPresentation {
                        ZStack {
                            fittedBackground(image, in: size)
                            fittedForeground(
                                image,
                                in: size,
                                sourceSize: measuredURL == url
                                    ? measuredSourceSize
                                    : nil,
                                accessibilityIdentifier: visualTestIdentifier
                            )
                        }
                            .transition(.opacity)
                    } else {
                        filledArtwork(image, in: size)
                            .transition(.opacity)
                    }
                case .empty, .failure:
                    if let continuityImage {
                        fittedContinuityArtwork(
                            Image(uiImage: continuityImage),
                            in: size,
                            usesFittedPresentation: usesFittedPresentation
                        )
                    } else {
                        Color.clear
                    }
                @unknown default:
                    Color.clear
                }
            }
        }
    }

    @ViewBuilder
    private func fittedBackground(in size: CGSize) -> some View {
        ZStack {
            MediaTheme.elevatedInk
            LinearGradient(
                colors: [
                    MediaTheme.gold.opacity(0.16),
                    Color(red: 0.10, green: 0.13, blue: 0.12),
                    MediaTheme.elevatedInk,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    @ViewBuilder
    private func fittedContinuityArtwork(
        _ image: Image,
        in size: CGSize,
        usesFittedPresentation: Bool
    ) -> some View {
        if usesFittedPresentation {
            ZStack {
                fittedBackground(image, in: size)
                fittedForeground(
                    image,
                    in: size,
                    sourceSize: continuityImage?.size,
                    accessibilityIdentifier: nil
                )
            }
        } else {
            filledArtwork(image, in: size)
        }
    }

    private func fittedBackground(_ image: Image, in size: CGSize) -> some View {
        image
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .scaleEffect(1.06)
            .blur(radius: 24, opaque: true)
            .saturation(0.82)
            .brightness(-0.10)
            .overlay { Color.black.opacity(0.18) }
    }

    private func filledArtwork(_ image: Image, in size: CGSize) -> some View {
        image
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
    }

    @ViewBuilder
    private func fittedForeground(
        _ image: Image,
        in size: CGSize,
        sourceSize: CGSize?,
        accessibilityIdentifier: String?
    ) -> some View {
        if let accessibilityIdentifier {
            fittedArtwork(image, in: size, sourceSize: sourceSize)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("完整首页照片")
                .accessibilityIdentifier(accessibilityIdentifier)
        } else {
            fittedArtwork(image, in: size, sourceSize: sourceSize)
        }
    }

    @ViewBuilder
    private func fittedArtwork(
        _ image: Image,
        in size: CGSize,
        sourceSize: CGSize?
    ) -> some View {
        if let sourceSize,
           sourceSize.width > 0,
           sourceSize.height > 0 {
            let fittedSize = HomeHeroRenderPolicy.fittedSize(
                sourceSize: sourceSize,
                in: size
            )
            image
                .resizable()
                .scaledToFit()
                .frame(width: fittedSize.width, height: fittedSize.height)
                .shadow(color: .black.opacity(0.28), radius: 16)
        } else {
            image
                .resizable()
                .scaledToFit()
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(0.28), radius: 16)
        }
    }

    private var placeholder: some View {
        ZStack {
            MediaTheme.elevatedInk
            LinearGradient(
                colors: [.white.opacity(0.035), .clear, MediaTheme.gold.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

#if DEBUG
private struct HomeHeroLayoutProbe: UIViewRepresentable {
    let identifier: String
    let sourceSize: CGSize

    func makeUIView(context: Context) -> HomeHeroLayoutProbeView {
        let view = HomeHeroLayoutProbeView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: HomeHeroLayoutProbeView, context: Context) {
        view.configure(identifier: identifier, sourceSize: sourceSize)
    }
}

private final class HomeHeroLayoutProbeView: UIView {
    private lazy var probeElement = UIAccessibilityElement(accessibilityContainer: self)
    private var sourceSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        probeElement.accessibilityLabel = "完整首页照片布局范围"
        accessibilityElements = [probeElement]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(identifier: String, sourceSize: CGSize) {
        probeElement.accessibilityIdentifier = identifier
        self.sourceSize = sourceSize
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let fittedSize = HomeHeroRenderPolicy.fittedSize(
            sourceSize: sourceSize,
            in: bounds.size
        )
        probeElement.accessibilityFrameInContainerSpace = CGRect(
            x: (bounds.width - fittedSize.width) / 2,
            y: (bounds.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }
}
#endif
