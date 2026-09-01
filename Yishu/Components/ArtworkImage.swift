import AVFoundation
import ImageIO
import SwiftUI
import UIKit

enum ArtworkImageLoadError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case payloadTooLarge
    case decodeFailed
}

enum ArtworkImageRetryPolicy {
    static let maximumAttempts = 3

    static func shouldRetry(_ error: Error) -> Bool {
        if case let ArtworkImageLoadError.httpStatus(statusCode) = error {
            return [408, 425, 429, 500, 502, 503, 504].contains(statusCode)
        }
        guard let urlError = error as? URLError else { return false }
        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .networkConnectionLost,
            .notConnectedToInternet,
            .resourceUnavailable,
            .secureConnectionFailed,
            .dataNotAllowed,
            .cannotLoadFromNetwork,
        ].contains(urlError.code)
    }

    static func retryDelayNanoseconds(afterAttempt attempt: Int) -> UInt64 {
        attempt <= 1 ? 350_000_000 : 850_000_000
    }

    static func diagnosticCode(for error: Error) -> Int {
        if let urlError = error as? URLError {
            return 10_000 + abs(urlError.code.rawValue)
        }
        switch error as? ArtworkImageLoadError {
        case .httpStatus(let statusCode):
            return 20_000 + max(0, statusCode)
        case .payloadTooLarge:
            return 30_001
        case .decodeFailed:
            return 30_002
        case .invalidResponse:
            return 30_003
        case nil:
            return 30_000
        }
    }
}

enum ArtworkImageLifecyclePolicy {
    static func shouldReloadWhenActive(url: URL?, hasImage: Bool) -> Bool {
        url != nil && !hasImage
    }
}

/// A small, size-aware image pipeline. `AsyncImage` decodes the original file
/// before SwiftUI scales it, which is expensive for the 2560 px portfolio
/// artwork. This pipeline creates a thumbnail close to the actual view size and
/// coalesces duplicate requests made by adjacent carousel/gallery views.
private actor ArtworkImagePipeline {
    static let shared = ArtworkImagePipeline()
    private static let maximumResponseBytes: Int64 = 20 * 1024 * 1024
    private static let maximumPixelDimension: Int64 = 30_000
    private static let maximumPixelCount: Int64 = 200_000_000

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 24
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    private let previewCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 16
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    private var inFlight: [String: Task<UIImage, Error>] = [:]
    private let session = SecureURLSessionFactory.make(
        requestTimeout: 8,
        resourceTimeout: 30
    )

    func image(for url: URL, maxPixelSize: Int) async throws -> UIImage {
        guard ContentSecurityPolicy.isTrustedMediaURL(url) else {
            throw ArtworkImageLoadError.invalidResponse
        }
        let bucket = min(3_000, max(320, ((maxPixelSize + 159) / 160) * 160))
        let key = "\(url.absoluteString)#\(bucket)"
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        if let existing = inFlight[key] {
            return try await existing.value
        }

        let imageSession = session
        let task = Task.detached(priority: .utility) { () throws -> UIImage in
            var latestError: Error = URLError(.unknown)
            for attempt in 1...ArtworkImageRetryPolicy.maximumAttempts {
                do {
                    var request = URLRequest(url: url)
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    // Fail a stalled handshake quickly enough for the bounded
                    // retry to recover while a launch poster is still visible.
                    // Active downloads retain the longer resource deadline.
                    request.timeoutInterval = 8
                    request.setValue(
                        "image/avif,image/webp,image/heic,image/heif,image/jpeg,image/png",
                        forHTTPHeaderField: "Accept"
                    )
                    request.setValue("Yishu-iOS/2.1", forHTTPHeaderField: "User-Agent")

                    let (data, response) = try await imageSession.data(for: request)
                    guard let http = response as? HTTPURLResponse,
                          ContentSecurityPolicy.matchesRequestedMediaURL(http.url, requestedURL: url) else {
                        throw ArtworkImageLoadError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw ArtworkImageLoadError.httpStatus(http.statusCode)
                    }
                    guard AppNetworkSecurityPolicy.isImageMIMEType(
                        http.value(forHTTPHeaderField: "Content-Type")
                    ), AppNetworkSecurityPolicy.permitsResponseLength(
                        http.expectedContentLength,
                        maximumBytes: Self.maximumResponseBytes
                    ) else {
                        throw ArtworkImageLoadError.invalidResponse
                    }
                    guard Int64(data.count) <= Self.maximumResponseBytes else {
                        throw ArtworkImageLoadError.payloadTooLarge
                    }
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          Self.hasSafePixelDimensions(source),
                          let cgImage = CGImageSourceCreateThumbnailAtIndex(
                            source,
                            0,
                            [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: bucket,
                                kCGImageSourceShouldCacheImmediately: true,
                            ] as CFDictionary
                          ) else {
                        throw ArtworkImageLoadError.decodeFailed
                    }
                    return UIImage(cgImage: cgImage)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    latestError = error
                    guard attempt < ArtworkImageRetryPolicy.maximumAttempts,
                          ArtworkImageRetryPolicy.shouldRetry(error) else {
                        throw error
                    }
                    try await Task.sleep(
                        nanoseconds: ArtworkImageRetryPolicy.retryDelayNanoseconds(
                            afterAttempt: attempt
                        )
                    )
                }
            }
            throw latestError
        }
        inFlight[key] = task

        do {
            let image = try await task.value
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            cache.setObject(image, forKey: key as NSString, cost: cost)
            previewCache.setObject(
                image,
                forKey: url.absoluteString as NSString,
                cost: cost
            )
            inFlight[key] = nil
            return image
        } catch {
            inFlight[key] = nil
            AppDiagnostics.shared.recordImageLoadFailure(
                category: ArtworkImageRetryPolicy.diagnosticCode(for: error)
            )
            throw error
        }
    }

    func cachedPreview(for url: URL) -> UIImage? {
        previewCache.object(forKey: url.absoluteString as NSString)
    }

    func purgeMemory() {
        cache.removeAllObjects()
        previewCache.removeAllObjects()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }

    private static func hasSafePixelDimensions(_ source: CGImageSource) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
              width > 0,
              height > 0,
              width <= maximumPixelDimension,
              height <= maximumPixelDimension else { return false }
        return width * height <= maximumPixelCount
    }
}

enum ArtworkImagePrefetcher {
    static func prefetch(urls: [URL], maxPixelSize: Int) async {
        let uniqueURLs = Array(Set(urls))
        await withTaskGroup(of: Void.self) { group in
            for url in uniqueURLs {
                group.addTask {
                    _ = try? await ArtworkImagePipeline.shared.image(
                        for: url,
                        maxPixelSize: maxPixelSize
                    )
                }
            }
        }
    }

    static func purgeMemory() async {
        await ArtworkImagePipeline.shared.purgeMemory()
    }
}

struct DownsampledAsyncImage<Content: View>: View {
    let url: URL?
    let targetSize: CGSize
    var maximumPixelSize: Int = 2_200
    var showsRetryButton = true
    let content: (AsyncImagePhase) -> Content

    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @State private var image: UIImage?
    @State private var loadedURL: URL?
    @State private var error: Error?
    @State private var retryGeneration = 0

    init(
        url: URL?,
        targetSize: CGSize,
        maximumPixelSize: Int = 2_200,
        showsRetryButton: Bool = true,
        @ViewBuilder content: @escaping (AsyncImagePhase) -> Content
    ) {
        self.url = url
        self.targetSize = targetSize
        self.maximumPixelSize = maximumPixelSize
        self.showsRetryButton = showsRetryButton
        self.content = content
    }

    private var maxPixelSize: Int {
        min(
            maximumPixelSize,
            Int(ceil(max(targetSize.width, targetSize.height) * displayScale))
        )
    }

    private var requestID: String {
        guard let url else { return "missing" }
        return "\(url.absoluteString)#\(maxPixelSize)#\(retryGeneration)"
    }

    var body: some View {
        // Keep the loading task attached even when a caller intentionally
        // renders no placeholder for the `.empty` phase.
        ZStack {
            content(phase)

            if error != nil, showsRetryButton {
                Button(action: retry) {
                    Label("重新加载", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .frame(minWidth: 44, minHeight: 44)
                        .foregroundStyle(AppTheme.warmWhite)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(AppTheme.gold.opacity(0.55), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("重新加载图片")
                .accessibilityHint("再次尝试加载当前图片")
                .accessibilityIdentifier("artwork-image-retry")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: requestID) {
            if loadedURL != url {
                image = nil
                loadedURL = nil
            }
            error = nil
            guard let url, maxPixelSize > 0 else { return }
            if let cachedPreview = await ArtworkImagePipeline.shared.cachedPreview(for: url) {
                guard !Task.isCancelled else { return }
                image = cachedPreview
                loadedURL = url
            }
            do {
                let loaded = try await ArtworkImagePipeline.shared.image(
                    for: url,
                    maxPixelSize: maxPixelSize
                )
                guard !Task.isCancelled else { return }
                image = loaded
                loadedURL = url
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Entering the background deliberately purges the volatile image
            // cache and cancels in-flight downloads. Resume any still-empty
            // view on activation even when cancellation produced no error.
            guard phase == .active,
                  ArtworkImageLifecyclePolicy.shouldReloadWhenActive(
                    url: url,
                    hasImage: image != nil
                  ) else { return }
            retryGeneration &+= 1
        }
    }

    private func retry() {
        retryGeneration &+= 1
    }

    private var phase: AsyncImagePhase {
        if let image { return .success(Image(uiImage: image)) }
        if let error { return .failure(error) }
        return .empty
    }
}

struct ArtworkImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    var body: some View {
        GeometryReader { proxy in
            DownsampledAsyncImage(
                url: url,
                targetSize: proxy.size
            ) { phase in
                switch phase {
                case .empty:
                    placeholder
                        .overlay { ProgressView().tint(AppTheme.gold) }
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .animation(.easeOut(duration: 0.25), value: url)
                        .transition(.opacity)
                case .failure:
                    placeholder
                        .overlay {
                            Image(systemName: "photo")
                                .font(.title2)
                                .foregroundStyle(AppTheme.muted)
                        }
                @unknown default:
                    placeholder
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .clipped()
    }

    private var placeholder: some View {
        ZStack {
            AppTheme.elevatedInk
            LinearGradient(
                colors: [.white.opacity(0.03), .clear, .white.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

struct SectionHeading: View {
    let eyebrow: String
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 7) {
                Text(eyebrow)
                    .font(.caption2.weight(.semibold))
                    .tracking(2.2)
                    .foregroundStyle(AppTheme.gold)
                Text(title)
                    .font(.system(.title2, design: .serif))
                    .foregroundStyle(AppTheme.warmWhite)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
            }
        }
    }
}

struct PillLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .tracking(1.2)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().stroke(.white.opacity(0.16)) }
    }
}

struct CollaborationContactButton<Label: View>: View {
    @Environment(\.openURL) private var openURL
    @State private var showMailFallback = false
    private let label: () -> Label

    init(@ViewBuilder label: @escaping () -> Label) {
        self.label = label
    }

    var body: some View {
        Button {
            openURL(ContentCatalog.collaborationEmailURL) { accepted in
                guard !accepted else { return }
                UIPasteboard.general.string = ContentCatalog.collaborationEmailAddress
                showMailFallback = true
            }
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .alert("未找到可用的邮件应用", isPresented: $showMailFallback) {
            Button("打开 QQ 邮箱网页版") {
                openURL(ContentCatalog.qqMailWebURL)
            }
            Button("知道了", role: .cancel) { }
        } message: {
            Text("联系邮箱 \(ContentCatalog.collaborationEmailAddress) 已复制，也可打开网页版邮箱继续发送。")
        }
    }
}

struct ArtworkVideoSurface: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill

    func makeUIView(context: Context) -> ArtworkPlayerLayerView {
        let view = ArtworkPlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        return view
    }

    func updateUIView(_ view: ArtworkPlayerLayerView, context: Context) {
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
    }

    static func dismantleUIView(_ view: ArtworkPlayerLayerView, coordinator: Void) {
        view.playerLayer.player = nil
    }
}

final class ArtworkPlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

enum VideoAudioSession {
    @discardableResult
    static func activate() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
            try session.setActive(true)
            return true
        } catch {
            return false
        }
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private struct ScreenCaptureProtectionModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCaptureActive = false
    @State private var hasEnteredActiveState = false
    @State private var isPrivacyCoverVisible = false
    @State private var isScreenshotWarningVisible = false
    @State private var screenshotWarningTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        ZStack {
            content
                // When the privacy cover is visible, protected controls and
                // descriptions must not remain reachable behind it in the
                // VoiceOver rotor.
                .accessibilityHidden(shouldShowProtectionCover)
                .allowsHitTesting(!shouldShowProtectionCover)

            if shouldShowProtectionCover {
                CaptureProtectionCover()
                    .zIndex(10_000)
                    .transition(.opacity)
            }
        }
        .background {
            SceneCaptureStateObserver { captured in
                applyCaptureState(captured)
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .onAppear {
            refreshCaptureState()
            updatePrivacyCover(for: scenePhase)
        }
        .onChange(of: scenePhase) { _, phase in
            refreshCaptureState()
            updatePrivacyCover(for: phase)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            refreshCaptureState()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            showScreenshotWarning()
        }
        .onDisappear {
            screenshotWarningTask?.cancel()
        }
    }

    private func refreshCaptureState() {
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        applyCaptureState(windowScenes
            .contains { $0.traitCollection.sceneCaptureState == .active }
        )
    }

    private func applyCaptureState(_ captured: Bool) {
        guard isCaptureActive != captured else { return }
        isCaptureActive = captured
        if captured {
            Task { await ArtworkImagePrefetcher.purgeMemory() }
        }
    }

    private func updatePrivacyCover(for phase: ScenePhase) {
        if phase == .active {
            hasEnteredActiveState = true
            isPrivacyCoverVisible = false
        } else {
            // A cold launch begins in `.inactive`. Covering that first frame was
            // the source of the long black screen. Privacy covering is only
            // needed after the app has already displayed protected content.
            isPrivacyCoverVisible = hasEnteredActiveState
        }
    }

    private func showScreenshotWarning() {
        guard !disablesProtectionForVisualTesting else { return }
        screenshotWarningTask?.cancel()
        if reduceMotion {
            isScreenshotWarningVisible = true
        } else {
            withAnimation(.easeOut(duration: 0.12)) {
                isScreenshotWarningVisible = true
            }
        }
        screenshotWarningTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled, scenePhase == .active, !isCaptureActive else { return }
            if reduceMotion {
                isScreenshotWarningVisible = false
            } else {
                withAnimation(.easeIn(duration: 0.2)) {
                    isScreenshotWarningVisible = false
                }
            }
        }
    }

    private var shouldShowProtectionCover: Bool {
        if ScreenProtectionTesting.forcesCover { return true }
        return !disablesProtectionForVisualTesting &&
            (isCaptureActive || isPrivacyCoverVisible || isScreenshotWarningVisible)
    }

    private var disablesProtectionForVisualTesting: Bool {
        ScreenProtectionTesting.isDisabled
    }
}

enum ScreenProtectionTesting {
    static var isDisabled: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-disable-screen-protection-for-visual-testing") ||
        ProcessInfo.processInfo.environment["YISHU_DISABLE_SCREEN_PROTECTION_FOR_VISUAL_TESTING"] == "1"
#else
        false
#endif
    }

    static var forcesCover: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["YISHU_FORCE_SCREEN_PROTECTION_COVER"] == "1"
#else
        false
#endif
    }
}

struct CaptureProtectionCover: View {
    var body: some View {
        ZStack {
            AppTheme.ink

            RadialGradient(
                colors: [AppTheme.gold.opacity(0.16), .clear],
                center: .center,
                startRadius: 10,
                endRadius: 330
            )

            protectionPattern

            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Text("狐狸姐姐温馨提示")
                            .font(.caption.weight(.semibold))
                            .tracking(2.4)
                            .foregroundStyle(AppTheme.gold)

                        ZStack {
                            Circle()
                                .stroke(AppTheme.gold.opacity(0.22), lineWidth: 1)
                                .frame(width: 108, height: 108)
                            Circle()
                                .fill(AppTheme.gold.opacity(0.1))
                                .frame(width: 82, height: 82)
                            Image(systemName: "lock.shield.fill")
                                .font(.largeTitle.weight(.regular))
                                .foregroundStyle(AppTheme.gold)
                        }
                        .padding(.top, 36)

                        Text("影像内容已保护")
                            .font(.system(.title, design: .serif))
                            .foregroundStyle(AppTheme.warmWhite)
                            .padding(.top, 28)

                        Text("受版权保护的影像不提供保存或分享\n录屏、投屏或 App 离开前台时将自动隐藏")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .lineSpacing(7)
                            .foregroundStyle(.white.opacity(0.58))
                            .padding(.top, 16)

                        Capsule()
                            .fill(AppTheme.gold.opacity(0.7))
                            .frame(width: 32, height: 1)
                            .padding(.top, 28)

                        Text("PROTECTED CONTENT · YI SHU")
                            .font(.caption2.weight(.semibold))
                            .tracking(2.1)
                            .foregroundStyle(AppTheme.muted)
                            .padding(.top, 18)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("狐狸姐姐温馨提示：受版权保护的影像不提供保存或分享，录屏、投屏或 App 离开前台时将自动隐藏")
        .accessibilityAddTraits(.isHeader)
    }

    private var protectionPattern: some View {
        GeometryReader { proxy in
            Path { path in
                let spacing: CGFloat = 64
                let diagonal = proxy.size.width + proxy.size.height
                var offset = -proxy.size.height
                while offset < diagonal {
                    path.move(to: CGPoint(x: offset, y: 0))
                    path.addLine(to: CGPoint(x: offset + proxy.size.height, y: proxy.size.height))
                    offset += spacing
                }
            }
            .stroke(AppTheme.gold.opacity(0.035), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

private struct SceneCaptureStateObserver: UIViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeUIView(context: Context) -> SceneCaptureStateObserverView {
        SceneCaptureStateObserverView(onChange: onChange)
    }

    func updateUIView(_ view: SceneCaptureStateObserverView, context: Context) {
        view.onChange = onChange
        view.reportCurrentState()
    }
}

@MainActor
private final class SceneCaptureStateObserverView: UIView {
    var onChange: @MainActor (Bool) -> Void
    private var traitRegistration: (any UITraitChangeRegistration)?

    init(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        traitRegistration = registerForTraitChanges([UITraitSceneCaptureState.self]) {
            (view: SceneCaptureStateObserverView, _: UITraitCollection) in
            view.reportCurrentState()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportCurrentState()
    }

    func reportCurrentState() {
        onChange(traitCollection.sceneCaptureState == .active)
    }
}

enum SecureCaptureSurfaceOwner: String, Equatable {
    case appRoot = "app_root"
    case fullScreenPresentation = "full_screen_presentation"
}

/// Applies only App Store-supported capture-state and app-switcher protection.
/// iOS does not expose a public API that can prevent an ordinary screenshot of
/// still imagery. `owner` and `onExit` remain part of the call-site contract so
/// independently presented hierarchies can share this wrapper without relying
/// on UIKit's private secure-text rendering implementation.
struct SecureCaptureSurface<Content: View>: View {
    let owner: SecureCaptureSurfaceOwner
    let onExit: (() -> Void)?
    private let content: Content

    init(
        owner: SecureCaptureSurfaceOwner,
        onExit: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.owner = owner
        self.onExit = onExit
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .privacySensitive()
            .protectedFromScreenCapture()
    }
}

extension View {
    func protectedFromScreenCapture() -> some View {
        modifier(ScreenCaptureProtectionModifier())
    }
}
