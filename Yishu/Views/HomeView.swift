import SwiftUI
import UIKit
import Observation

enum HomeHeroPresentation: String, Equatable {
    case fill
    case fit
}

enum HomeHeroRenderPolicy {
    static func presentation(
        for viewport: CGSize,
        idiom: UIUserInterfaceIdiom
    ) -> HomeHeroPresentation {
        // A weekly selection can contain portrait, landscape and square art.
        // Cropping must not depend on the particular photograph selected today.
        .fit
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

    static func selectionAfterUpdate(previous: [URL], updated: [URL], selection: Int) -> Int {
        guard !updated.isEmpty else { return 0 }
        if previous.indices.contains(selection), let retained = updated.firstIndex(of: previous[selection]) {
            return retained
        }
        return min(max(0, selection), updated.count - 1)
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
        // The manifest caps the hero at five photographs. Keep their loading
        // views alive in BOTH directions, even while the paging controller's
        // selection still points at the page the finger is leaving.
        return true
    }

    static func prefetchIndices(
        selection: Int,
        count: Int,
        presentation: HomeHeroPresentation = .fill
    ) -> [Int] {
        guard count > 0, (0..<count).contains(selection) else { return [] }
        return Array(0..<count)
    }

    static func shouldAnimateTransition(from current: Int, to next: Int, count: Int) -> Bool {
        guard count > 1,
              (0..<count).contains(current),
              (0..<count).contains(next) else { return false }
        return abs(current - next) == 1
    }
}

/// Slots depend only on the safe viewport and text size, never image content
/// or a delayed geometry preference. A new image cannot move the whole page.
struct HomeGalleryLayout: Equatable {
    let image: CGRect
    let weather: CGRect
    let caption: CGRect
    let isSideBySide: Bool

    init(viewport: CGSize, accessibilityText: Bool) {
        let width = max(0, viewport.width)
        let height = max(0, viewport.height)
        let inset = min(width / 8, height / 8, width >= 700 ? 24.0 : 16.0)
        let gap = min(height / 12, height < 620 ? 10.0 : 16.0)
        let innerWidth = max(0, width - 2 * inset)
        let innerHeight = max(0, height - 2 * inset)
        let header = min(44.0, innerHeight)
        isSideBySide = width >= 600 && width > height

        if isSideBySide {
            let copyWidth = min(360, max(240, innerWidth * 0.31))
            let photoWidth = max(0, innerWidth - copyWidth - gap * 2)
            image = CGRect(x: inset, y: inset, width: photoWidth, height: innerHeight)
            let copyX = image.maxX + gap * 2
            weather = CGRect(x: copyX, y: inset, width: copyWidth, height: header)
            caption = CGRect(x: copyX, y: weather.maxY + gap, width: copyWidth,
                             height: max(0, innerHeight - header - gap))
        } else {
            weather = CGRect(x: inset, y: inset, width: innerWidth, height: header)
            let preferredCaption = accessibilityText ? 244.0 : (height < 620 ? 132.0 : 152.0)
            let captionHeight = min(preferredCaption, max(0, innerHeight - header - 2 * gap) * 0.48)
            let photoHeight = max(0, innerHeight - header - captionHeight - 2 * gap)
            image = CGRect(x: inset, y: weather.maxY + gap, width: innerWidth, height: photoHeight)
            caption = CGRect(x: inset, y: image.maxY + gap, width: innerWidth, height: captionHeight)
        }
    }
}

/// A changed identity cancels the old sleep, including an already-due tick.
/// A cancelled/unfinished drag must receive the same full dwell as a page turn.
struct HomeHeroAdvanceRequest: Equatable {
    let enabled: Bool
    let selection: Int
    let interactionGeneration: UInt

    static func permitsAdvance(isVisible: Bool, isActive: Bool, reducesMotion: Bool,
                               voiceOverEnabled: Bool, isTouching: Bool,
                               count: Int, currentReady: Bool, nextReady: Bool) -> Bool {
        isVisible && isActive && !reducesMotion && !voiceOverEnabled && !isTouching
            && count > 1 && currentReady && nextReady
    }
}

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
                    viewport: proxy.size,
                    showPortfolio: showPortfolio
                )
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbarColorScheme(AppearanceStore.shared.theme.colorScheme, for: .tabBar)
        .task {
            localWeather.refreshIfAuthorized()
        }
    }
}

/// One observable reference is shared by paging callbacks and overlay builders.
/// A copied value snapshot must not leave the caption and the visible page apart.
@MainActor @Observable
final class HomeHeroPlaybackState {
    var selection: Int
    var isVisible = false
    var isActive = false
    var landscapeContinuityImage: UIImage?
    var activeURLs: Set<URL> = []
    var selectedURL: URL?
    var isTouching = false {
        didSet {
            // Invalidate synchronously with UIKit contact events. SwiftUI may
            // coalesce a begin/end pair before onChange sees either edge;
            // the old sleeping task must still fail its generation check.
            if oldValue != isTouching { interactionGeneration &+= 1 }
        }
    }
    var interactionGeneration: UInt = 0
    var preparedImages: [URL: UIImage] = [:]
    var automaticAdvanceCount = 0

    init(selection: Int) { self.selection = selection }

    func recordPreparedImage(_ image: UIImage, for url: URL) {
        // Read live state, not the SwiftUI value captured before a weekly
        // manifest update, rotation or a transition into the background.
        guard isVisible, isActive, activeURLs.contains(url) else { return }
        preparedImages[url] = image
        if selectedURL == url { landscapeContinuityImage = image }
    }
}

private struct HeroPager: View {
    let imageURLs: [URL]
    let localWeather: LocalWeatherStore
    let viewport: CGSize
    let showPortfolio: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @State private var playback = HomeHeroPlaybackState(selection: HeroPager.visualTestInitialSelection)

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
        guard slides.indices.contains(playback.selection) else { return false }
        return !disablesAutoAdvanceForVisualTesting && HomeHeroAdvanceRequest.permitsAdvance(
            isVisible: playback.isVisible, isActive: scenePhase == .active, reducesMotion: reduceMotion,
            voiceOverEnabled: voiceOverEnabled, isTouching: playback.isTouching, count: slides.count,
            currentReady: holdsRemoteImagesForVisualTesting || playback.preparedImages[slides[playback.selection]] != nil,
            nextReady: holdsRemoteImagesForVisualTesting || playback.preparedImages[slides[(playback.selection + 1) % slides.count]] != nil
        )
    }

    private var advanceRequest: HomeHeroAdvanceRequest {
        HomeHeroAdvanceRequest(enabled: shouldAutoAdvance, selection: playback.selection,
                               interactionGeneration: playback.interactionGeneration)
    }

    var body: some View {
        let presentation = HomeHeroRenderPolicy.presentation(
            for: viewport,
            idiom: UIDevice.current.userInterfaceIdiom
        )
        let exposesVisualTestState = exposesHeroStateForVisualTesting
        let layout = HomeGalleryLayout(viewport: viewport, accessibilityText: dynamicTypeSize.isAccessibilitySize)

        ZStack(alignment: .topLeading) {
            TabView(selection: Binding(get: { playback.selection }, set: { playback.selection = $0 })) {
                ForEach(slides.indices, id: \.self) { index in
                    let url = slides[index]
                    let loadsRemoteImage = !holdsRemoteImagesForVisualTesting
                        && HomeHeroRenderPolicy.shouldLoadRemoteImage(
                            at: index,
                            selection: playback.selection,
                            count: slides.count,
                            presentation: presentation
                        )
                    let visualTestIdentifier = exposesVisualTestState
                        && index == playback.selection
                        ? "home-hero-actual-\(presentation == .fit ? "fitted" : "filled")-image-\(index)"
                        : nil

                    HeroSlideImage(
                        url: url,
                        loadsRemoteImage: loadsRemoteImage,
                        usesVisualTestArtwork: holdsRemoteImagesForVisualTesting,
                        presentation: presentation,
                        visualTestIdentifier: visualTestIdentifier,
                        preparedImage: playback.preparedImages[url],
                        continuityImage: playback.landscapeContinuityImage,
                        onImageLoaded: { loadedImage in
                            playback.recordPreparedImage(loadedImage, for: url)
                        }
                    )
                        .frame(width: layout.image.width, height: layout.image.height)
                        .clipped()
                        .accessibilityHidden(!exposesVisualTestState)
                        .tag(index)
                }
            }
            .frame(width: layout.image.width, height: layout.image.height)
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(HomeTouchObserver { playback.isTouching = $0 })
            .offset(x: layout.image.minX, y: layout.image.minY)

            weatherRow
                .frame(width: layout.weather.width, height: layout.weather.height)
                .offset(x: layout.weather.minX, y: layout.weather.minY)

            galleryCaption(in: layout)
                .frame(width: layout.caption.width, height: layout.caption.height)
                .offset(x: layout.caption.minX, y: layout.caption.minY)

            homeHeroVisualTestControls(
                presentation: presentation
            )
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        .task(id: prefetchRequestID(for: layout.image.size)) {
            guard !holdsRemoteImagesForVisualTesting, playback.isVisible, scenePhase == .active else { return }
            await ArtworkImagePrefetcher.prefetch(
                urls: prefetchURLs(for: presentation),
                maxPixelSize: min(
                    1_800,
                    max(
                        320,
                        Int(ceil(max(layout.image.width, layout.image.height) * displayScale))
                    )
                ),
                onImageLoaded: { url, image in
                    playback.recordPreparedImage(image, for: url)
                }
            )
        }
        .onAppear {
            playback.activeURLs = Set(slides)
            playback.selectedURL = slides.indices.contains(playback.selection) ? slides[playback.selection] : nil
            playback.isActive = scenePhase == .active
            playback.isVisible = true
        }
        .onDisappear {
            playback.isVisible = false
            playback.isActive = false
            playback.isTouching = false
            playback.landscapeContinuityImage = nil
            playback.preparedImages = [:]
            playback.activeURLs = []
            playback.selectedURL = nil
        }
        .onChange(of: scenePhase) { _, phase in
            playback.isActive = phase == .active
            if phase != .active {
                playback.isTouching = false
                playback.landscapeContinuityImage = nil
                playback.preparedImages = [:]
            }
        }
        .task(id: advanceRequest) {
            let request = advanceRequest
            guard request.enabled else { return }
            do {
                try await Task.sleep(for: .seconds(5))
                try Task.checkCancellation()
                guard advanceRequest == request else { return }
                playback.automaticAdvanceCount += 1
                setSelection((playback.selection + 1) % slides.count, animationDuration: 0.65)
            } catch { }
        }
        .onChange(of: slides) { oldSlides, newSlides in
            guard oldSlides != newSlides else { return }
            playback.activeURLs = Set(newSlides)
            playback.interactionGeneration &+= 1
            playback.preparedImages = playback.preparedImages.filter { newSlides.contains($0.key) }
            playback.landscapeContinuityImage = nil
            playback.selection = HomeHeroRenderPolicy.selectionAfterUpdate(
                previous: oldSlides, updated: newSlides, selection: playback.selection)
            playback.selectedURL = newSlides.indices.contains(playback.selection) ? newSlides[playback.selection] : nil
        }
        .onChange(of: playback.selection) { _, index in
            playback.selectedURL = slides.indices.contains(index) ? slides[index] : nil
            if slides.indices.contains(index), let image = playback.preparedImages[slides[index]] {
                playback.landscapeContinuityImage = image
            }
        }
    }

    private func galleryCaption(in layout: HomeGalleryLayout) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: layout.isSideBySide ? 18 : 8) {
                    heroTitle(font: .system(layout.isSideBySide ? .largeTitle : .title2, design: .serif),
                              multiline: layout.isSideBySide)
                    heroSubtitle
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: layout.isSideBySide ? max(0, layout.caption.height - 84) : nil,
                       alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.visible)
            .accessibilityIdentifier("home-hero-copy-scroll")

            HStack(spacing: 12) {
                portfolioButton
                Spacer(minLength: 0)
                pageIndicator
            }
            // Keep this row comfortably tappable without sacrificing the
            // whole photograph at AX sizes. The copy above remains scrollable.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .foregroundStyle(AppTheme.warmWhite)
    }

    private func heroTitle(font: Font, multiline: Bool) -> some View {
        Text(multiline ? "镜头之内，\n自有叙事。" : "镜头之内，自有叙事。")
            .font(font)
            .lineSpacing(multiline ? 4 : 2)
            .foregroundStyle(AppTheme.warmWhite)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("home-hero-title")
    }

    private var heroSubtitle: some View {
        Text("短剧演员 · 模特 · 视频创作者")
            .font(.footnote.weight(.medium))
            .tracking(0.9)
            .foregroundStyle(AppTheme.warmWhite)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("home-hero-subtitle")
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
            .background(AppTheme.warmWhite)
            .foregroundStyle(AppTheme.ink)
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
        .foregroundStyle(AppTheme.warmWhite)
    }

    private var weatherButton: some View {
        Button { openWeatherOrSettings() } label: {
            weatherSummary
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.warmWhite)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(AppTheme.elevatedInk, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(AppTheme.line, lineWidth: 0.5)
                }
                .shadow(color: AppTheme.surfaceShadow, radius: 6, y: 2)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                // VoiceOver receives one complete button summary below,
                // rather than duplicate icon and text nodes.
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
        // This compact utility now lives outside the photograph. VoiceOver
        // receives the complete weather summary even at the capped text size.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityIdentifier("home-weather")
        .accessibilityElement(children: .ignore)
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
        HStack(spacing: 8) {
            Text(String(format: "%02d", playback.selection + 1))
                .foregroundStyle(AppTheme.warmWhite)
            Rectangle().fill(AppTheme.line).frame(width: 24, height: 1)
                .accessibilityHidden(true)
            Text(String(format: "%02d", slides.count))
                .foregroundStyle(AppTheme.muted)
        }
        .font(.caption.monospacedDigit())
        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("首页照片")
        .accessibilityValue("第 \(playback.selection + 1) 张，共 \(slides.count) 张")
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
        let nextSelection = (playback.selection + offset + slides.count) % slides.count
        setSelection(nextSelection, animationDuration: 0.22)
    }

    private func setSelection(_ nextSelection: Int, animationDuration: Double) {
        let shouldAnimate = !reduceMotion
            && HomeHeroRenderPolicy.shouldAnimateTransition(
                from: playback.selection,
                to: nextSelection,
                count: slides.count
            )
        if shouldAnimate {
            withAnimation(.easeInOut(duration: animationDuration)) {
                playback.selection = nextSelection
            }
        } else {
            playback.selection = nextSelection
        }
    }

    private func prefetchURLs(for presentation: HomeHeroPresentation) -> [URL] {
        HomeHeroRenderPolicy.prefetchIndices(
            selection: playback.selection,
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
        return "\(playback.isVisible)#\(scenePhase == .active)#\(Int(size.width.rounded()))x\(Int(size.height.rounded()))#\(urls)"
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
                .accessibilityValue("第 \(playback.selection + 1) 张，共 \(slides.count) 张")
                .accessibilityIdentifier("home-hero-visual-state-\(playback.selection)")
                .id("home-hero-visual-state-\(playback.selection)")
                .allowsHitTesting(false)

            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("自动轮播次数")
                .accessibilityValue(String(playback.automaticAdvanceCount))
                .accessibilityIdentifier("home-hero-auto-advance-count")
                .allowsHitTesting(false)

            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("已在内存中准备的首页图片")
                .accessibilityValue(String(playback.preparedImages.count))
                .accessibilityIdentifier("home-hero-ready-count")
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
                .tint(AppTheme.gold)
        } else {
            Image(systemName: localWeather.symbolName)
        }
    }
}

/// Observe contact without competing with native scrolling.
/// This recognizer never recognizes, prevents another recognizer or cancels
/// delivery to controls. It works on the supported iOS 17+ range.
private struct HomeTouchObserver: UIViewRepresentable {
    let onContactChanged: (Bool) -> Void

    func makeUIView(context: Context) -> ContactView {
        let view = ContactView()
        view.isUserInteractionEnabled = false
        view.onContactChanged = onContactChanged
        return view
    }

    func updateUIView(_ uiView: ContactView, context: Context) {
        uiView.onContactChanged = onContactChanged
    }

    final class ContactView: UIView, UIGestureRecognizerDelegate {
        var onContactChanged: ((Bool) -> Void)?
        private weak var observingWindow: UIWindow?
        private lazy var contact = ContactRecognizer { [weak self] touching in
            self?.onContactChanged?(touching)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard observingWindow !== window else { return }
            contact.isEnabled = false
            observingWindow?.removeGestureRecognizer(contact)
            observingWindow = window
            contact.delegate = self
            contact.isEnabled = true
            window?.addGestureRecognizer(contact)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let window, !isHidden else { return false }
            return convert(bounds, to: window).contains(touch.location(in: window))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }

    final class ContactRecognizer: UIGestureRecognizer {
        private var contacts = Set<UITouch>()
        private let onContactChanged: (Bool) -> Void

        init(onContactChanged: @escaping (Bool) -> Void) {
            self.onContactChanged = onContactChanged
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            let wasEmpty = contacts.isEmpty
            contacts.formUnion(touches)
            if wasEmpty { onContactChanged(true) }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            finish(touches)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            // Contact remains active; native recognizers alone interpret motion.
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            finish(touches)
        }

        override func reset() {
            super.reset()
            if !contacts.isEmpty {
                contacts.removeAll()
                onContactChanged(false)
            }
        }

        private func finish(_ touches: Set<UITouch>) {
            let wasTouching = !contacts.isEmpty
            contacts.subtract(touches)
            if wasTouching && contacts.isEmpty {
                onContactChanged(false)
                state = .failed
            }
        }
    }
}

private struct HeroSlideImage: View {
    let url: URL
    let loadsRemoteImage: Bool
    let usesVisualTestArtwork: Bool
    let presentation: HomeHeroPresentation
    let visualTestIdentifier: String?
    let preparedImage: UIImage?
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
        let sourceSize = visualTestSourceSize
        if presentation == .fit {
            let fittedSize = HomeHeroRenderPolicy.fittedSize(
                sourceSize: sourceSize,
                in: size
            )
            ZStack {
                fittedBackground(in: size)

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

#if DEBUG
    private var visualTestSourceSize: CGSize {
        guard ProcessInfo.processInfo.arguments.contains("-home-hero-varied-aspects-for-visual-testing") else {
            return CGSize(width: 959, height: 1_440)
        }
        let sizes = [CGSize(width: 959, height: 1440), CGSize(width: 1440, height: 959),
                     CGSize(width: 1200, height: 1200), CGSize(width: 2400, height: 600),
                     CGSize(width: 800, height: 1600)]
        return sizes[(ContentCatalog.heroImages.firstIndex(of: url) ?? 0) % sizes.count]
    }
#endif

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
                            fittedBackground(in: size)
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
                    ZStack {
                        if let preview = preparedImage ?? continuityImage {
                            fittedContinuityArtwork(
                                Image(uiImage: preview),
                                in: size,
                                usesFittedPresentation: usesFittedPresentation,
                                sourceSize: preview.size
                            )
                        }
                        // Do not leave an animating spinner underneath every
                        // successfully loaded page, or show one after failure.
                        if case .empty = phase, preparedImage == nil {
                            ProgressView().tint(AppTheme.gold)
                        }
                    }
                @unknown default:
                    Color.clear
                }
            }
        }
    }

    @ViewBuilder
    private func fittedBackground(in size: CGSize) -> some View {
        AppTheme.ink
    }

    @ViewBuilder
    private func fittedContinuityArtwork(
        _ image: Image,
        in size: CGSize,
        usesFittedPresentation: Bool,
        sourceSize: CGSize
    ) -> some View {
        if usesFittedPresentation {
            ZStack {
                fittedBackground(in: size)
                fittedForeground(
                    image,
                    in: size,
                    sourceSize: sourceSize,
                    accessibilityIdentifier: nil
                )
            }
        } else {
            filledArtwork(image, in: size)
        }
    }

    private func filledArtwork(_ image: Image, in size: CGSize) -> some View {
        image
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("首页照片")
            .accessibilityIdentifier(visualTestIdentifier ?? "")
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
                .shadow(color: AppTheme.surfaceShadow, radius: 16)
        } else {
            image
                .resizable()
                .scaledToFit()
                .frame(width: size.width, height: size.height)
                .shadow(color: AppTheme.surfaceShadow, radius: 16)
        }
    }

    private var placeholder: some View {
        ZStack {
            AppTheme.elevatedInk
            LinearGradient(
                colors: [AppTheme.subtleFill, .clear, AppTheme.gold.opacity(0.05)],
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
