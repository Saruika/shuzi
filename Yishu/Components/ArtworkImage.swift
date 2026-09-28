import AVFoundation
import ImageIO
import OSLog
import SwiftUI
import UIKit

private struct AppServiceEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppServiceEnvironment = .production
}

extension EnvironmentValues {
    var appServiceEnvironment: AppServiceEnvironment {
        get { self[AppServiceEnvironmentKey.self] }
        set { self[AppServiceEnvironmentKey.self] = newValue }
    }
}

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

#if DEBUG
/// Deterministic in-memory raster for gesture tests, not artist content and
/// never bundled into Release. Still passes the real image decoder and cache.
enum ArtworkImageUITestFixture {
    static func response(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw ArtworkImageLoadError.invalidResponse }
        let data = await MainActor.run {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(size: CGSize(width: 400, height: 600), format: format)
                .pngData { context in
                    UIColor.systemTeal.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
                    UIColor.white.setFill()
                    for row in stride(from: 20, through: 560, by: 80) {
                        context.fill(CGRect(x: 20, y: row, width: 360, height: 20))
                    }
                }
        }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/png", "Content-Length": String(data.count)]) else {
            throw ArtworkImageLoadError.invalidResponse
        }
        return (data, response)
    }
}
#endif

/// A small, size-aware image pipeline. `AsyncImage` decodes the original file
/// before SwiftUI scales it, which is expensive for the 2560 px portfolio
/// artwork. This pipeline creates a thumbnail close to the actual view size and
/// coalesces duplicate requests made by adjacent carousel/gallery views.
actor ArtworkImagePipeline {
    static let shared = ArtworkImagePipeline()
    private static let review = ArtworkImagePipeline(environment: .review)
    static func pipeline(for environment: AppServiceEnvironment) -> ArtworkImagePipeline {
        environment == .production ? shared : review
    }
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
    private struct Flight {
        let id = UUID()
        let task: Task<UIImage, Error>
    }
    private var inFlight: [String: Flight] = [:]
    private var generation: UInt64 = 0
    private let environment: AppServiceEnvironment
    private let dataLoader: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?
    private let session = SecureURLSessionFactory.make(
        requestTimeout: 8,
        resourceTimeout: 30
    )

    init(environment: AppServiceEnvironment = .production,
         dataLoader: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil) {
        self.environment = environment
#if DEBUG
        if dataLoader == nil && ProcessInfo.processInfo.arguments.contains("-use-deterministic-gallery-images-for-testing") {
            self.dataLoader = { try await ArtworkImageUITestFixture.response(for: $0) }
        } else {
            self.dataLoader = dataLoader
        }
#else
        self.dataLoader = dataLoader
#endif
    }

    func image(for url: URL, maxPixelSize: Int) async throws -> UIImage {
        try Task.checkCancellation()
        guard ContentSecurityPolicy.isTrustedMediaURL(url, environment: environment) else {
            throw ArtworkImageLoadError.invalidResponse
        }
        let bucket = min(3_000, max(320, ((maxPixelSize + 159) / 160) * 160))
        let key = "\(url.absoluteString)#\(bucket)"
        let requestGeneration = generation
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        if let existing = inFlight[key] {
            let image = try await existing.task.value
            try Task.checkCancellation()
            guard requestGeneration == generation else { throw CancellationError() }
            return image
        }

        let imageSession = session
        let dataLoader = dataLoader
        let environment = environment
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
                    request.setValue(AppNetworkIdentity.userAgent(for: .image), forHTTPHeaderField: "User-Agent")

                    let (data, response): (Data, URLResponse)
                    if let dataLoader { (data, response) = try await dataLoader(request) }
                    else { (data, response) = try await imageSession.data(for: request) }
                    try Task.checkCancellation()
                    guard let http = response as? HTTPURLResponse,
                          ContentSecurityPolicy.matchesRequestedMediaURL(http.url, requestedURL: url, environment: environment) else {
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
                    try Task.checkCancellation()
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
        let flight = Flight(task: task)
        inFlight[key] = flight

        do {
            let image = try await task.value
            guard requestGeneration == generation, inFlight[key]?.id == flight.id else {
                throw CancellationError()
            }
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            cache.setObject(image, forKey: key as NSString, cost: cost)
            previewCache.setObject(
                image,
                forKey: url.absoluteString as NSString,
                cost: cost
            )
            inFlight[key] = nil
            try Task.checkCancellation()
            return image
        } catch {
            // A cancelled old flight must not erase a replacement for the same URL.
            if inFlight[key]?.id == flight.id { inFlight[key] = nil }
            if !(error is CancellationError) {
                AppDiagnostics.shared.recordImageLoadFailure(
                    category: ArtworkImageRetryPolicy.diagnosticCode(for: error)
                )
            }
            throw error
        }
    }

    func cachedPreview(for url: URL) -> UIImage? {
        guard ContentSecurityPolicy.isTrustedMediaURL(url, environment: environment) else { return nil }
        return previewCache.object(forKey: url.absoluteString as NSString)
    }

    func purgeMemory() {
        generation &+= 1
        cache.removeAllObjects()
        previewCache.removeAllObjects()
        inFlight.values.forEach { $0.task.cancel() }
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
    static func prefetch(urls: [URL], maxPixelSize: Int,
                         environment: AppServiceEnvironment = .production,
                         onImageLoaded: (@MainActor (URL, UIImage) -> Void)? = nil) async {
        let uniqueURLs = Array(Set(urls))
        await withTaskGroup(of: Void.self) { group in
            for url in uniqueURLs {
                group.addTask {
                    if let image = try? await ArtworkImagePipeline.pipeline(for: environment).image(
                        for: url,
                        maxPixelSize: maxPixelSize
                    ), !Task.isCancelled {
                        await onImageLoaded?(url, image)
                    }
                }
            }
        }
    }

    static func purgeMemory() async {
        for environment in AppServiceEnvironment.allCases {
            await ArtworkImagePipeline.pipeline(for: environment).purgeMemory()
        }
    }
}

struct DownsampledAsyncImage<Content: View>: View {
    let url: URL?
    let targetSize: CGSize
    var maximumPixelSize: Int = 2_200
    var showsRetryButton = true
    var onImageLoaded: ((UIImage) -> Void)?
    let content: (AsyncImagePhase) -> Content

    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appServiceEnvironment) private var serviceEnvironment
    @State private var image: UIImage?
    @State private var loadedURL: URL?
    @State private var loadedEnvironment: AppServiceEnvironment?
    @State private var error: Error?
    @State private var retryGeneration = 0

    init(
        url: URL?,
        targetSize: CGSize,
        maximumPixelSize: Int = 2_200,
        showsRetryButton: Bool = true,
        onImageLoaded: ((UIImage) -> Void)? = nil,
        @ViewBuilder content: @escaping (AsyncImagePhase) -> Content
    ) {
        self.url = url
        self.targetSize = targetSize
        self.maximumPixelSize = maximumPixelSize
        self.showsRetryButton = showsRetryButton
        self.onImageLoaded = onImageLoaded
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
        return "\(serviceEnvironment.rawValue)#\(url.absoluteString)#\(maxPixelSize)#\(retryGeneration)"
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
            if loadedURL != url || loadedEnvironment != serviceEnvironment {
                image = nil
                loadedURL = nil
                loadedEnvironment = nil
            }
            error = nil
            guard let url, maxPixelSize > 0 else { return }
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-fail-artwork-for-visual-testing") {
                image = nil
                loadedURL = nil
                loadedEnvironment = nil
                error = ArtworkImageLoadError.httpStatus(503)
                return
            }
#endif
            let pipeline = ArtworkImagePipeline.pipeline(for: serviceEnvironment)
            if let cachedPreview = await pipeline.cachedPreview(for: url) {
                guard !Task.isCancelled else { return }
                publish(cachedPreview, for: url)
            }
            do {
                let loaded = try await pipeline.image(
                    for: url,
                    maxPixelSize: maxPixelSize
                )
                guard !Task.isCancelled else { return }
                publish(loaded, for: url)
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

    private func publish(_ loadedImage: UIImage, for url: URL) {
        let shouldNotify = image !== loadedImage || loadedURL != url
        image = loadedImage
        loadedURL = url
        loadedEnvironment = serviceEnvironment
        if shouldNotify {
            onImageLoaded?(loadedImage)
        }
    }

    private var phase: AsyncImagePhase {
        if let image, loadedEnvironment == serviceEnvironment {
            return .success(Image(uiImage: image))
        }
        if let error { return .failure(error) }
        return .empty
    }
}

struct ArtworkImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var showsRetryButton = true

    var body: some View {
        GeometryReader { proxy in
            DownsampledAsyncImage(
                url: url,
                targetSize: proxy.size,
                showsRetryButton: showsRetryButton
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

enum ScreenCaptureStatus: Int, Equatable {
    case unknown = -1
    case inactive = 0
    case active = 1

    init(_ state: UISceneCaptureState) {
        switch state {
        case .active: self = .active
        case .inactive: self = .inactive
        case .unspecified: self = .unknown
        @unknown default: self = .unknown
        }
    }
}

/// One atomic sample from the owning window, never a mixture of unrelated scenes.
struct ScreenCaptureSample: Equatable {
    let sceneStatus: ScreenCaptureStatus
    let screenIsCaptured: Bool
    let isAttached: Bool
    let isSceneActive: Bool

    var status: ScreenCaptureStatus {
        guard isAttached else { return .unknown }
        if sceneStatus == .active || screenIsCaptured { return .active }
        // A false screen signal must not override an unknown scene signal.
        return sceneStatus == .inactive && isSceneActive ? .inactive : .unknown
    }

    static let detached = ScreenCaptureSample(
        sceneStatus: .unknown, screenIsCaptured: false,
        isAttached: false, isSceneActive: false
    )
}

struct ScreenProtectionPresentationState: Equatable {
    private(set) var captureStatus = ScreenCaptureStatus.unknown
    var isCaptureActive: Bool { captureStatus == .active }
    private(set) var hasEnteredActiveState = false
    private(set) var isPrivacyCoverVisible = false
    private(set) var isScreenshotWarningVisible = false
    private(set) var screenshotWarningGeneration: UInt = 0

    var shouldShowProtectionCover: Bool {
        captureStatus != .inactive || isPrivacyCoverVisible || isScreenshotWarningVisible
    }

    @discardableResult
    mutating func updateCapture(_ status: ScreenCaptureStatus) -> Bool {
        guard status != .unknown else { return false }
        let didBeginCapture = status == .active && !isCaptureActive
        captureStatus = status
        return didBeginCapture
    }

    mutating func updateScene(isActive: Bool) {
        if isActive {
            hasEnteredActiveState = true
            isPrivacyCoverVisible = false
        } else {
            // Do not cover the initial inactive frame of a cold launch. No
            // protected content has been visible before the first active state.
            isPrivacyCoverVisible = hasEnteredActiveState
        }
    }

    @discardableResult
    mutating func beginScreenshotWarning() -> UInt {
        screenshotWarningGeneration &+= 1
        isScreenshotWarningVisible = true
        return screenshotWarningGeneration
    }

    mutating func expireScreenshotWarning(generation: UInt) {
        guard generation == screenshotWarningGeneration else { return }
        isScreenshotWarningVisible = false
    }

    mutating func cancelScreenshotWarning() {
        // Invalidate an already-resumed task as well as one that has not yet
        // observed cooperative cancellation.
        screenshotWarningGeneration &+= 1
        isScreenshotWarningVisible = false
    }
}

private struct ScreenCaptureProtectionModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var protectionState = ScreenProtectionPresentationState()
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
                    .transition(.identity)
                    .transaction { $0.animation = nil; $0.disablesAnimations = true }
            }
        }
        .background {
            SceneCaptureStateObserver { status in
                applyCaptureState(status)
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .onAppear {
            updatePrivacyCover(for: scenePhase)
        }
        .onChange(of: scenePhase) { _, phase in
            updatePrivacyCover(for: phase)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            showScreenshotWarning()
        }
        .onDisappear {
            screenshotWarningTask?.cancel()
            screenshotWarningTask = nil
            protectionState.cancelScreenshotWarning()
        }
    }

    private func applyCaptureState(_ status: ScreenCaptureStatus) {
        if protectionState.updateCapture(status) {
            Task { await ArtworkImagePrefetcher.purgeMemory() }
        }
    }

    private func updatePrivacyCover(for phase: ScenePhase) {
        protectionState.updateScene(isActive: phase == .active)
    }

    private func showScreenshotWarning() {
        guard !disablesProtectionForVisualTesting else { return }
        screenshotWarningTask?.cancel()
        let generation: UInt
        if reduceMotion {
            generation = protectionState.beginScreenshotWarning()
        } else {
            generation = withAnimation(.easeOut(duration: 0.12)) {
                protectionState.beginScreenshotWarning()
            }
        }
        screenshotWarningTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(1.8))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            if reduceMotion {
                protectionState.expireScreenshotWarning(generation: generation)
            } else {
                withAnimation(.easeIn(duration: 0.2)) {
                    protectionState.expireScreenshotWarning(generation: generation)
                }
            }
        }
    }

    private var shouldShowProtectionCover: Bool {
        if ScreenProtectionTesting.forcesCover { return true }
        return !disablesProtectionForVisualTesting &&
            protectionState.shouldShowProtectionCover
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
            MediaTheme.ink

            RadialGradient(
                colors: [MediaTheme.gold.opacity(0.16), .clear],
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
                            .foregroundStyle(MediaTheme.gold)

                        ZStack {
                            Circle()
                                .stroke(MediaTheme.gold.opacity(0.22), lineWidth: 1)
                                .frame(width: 108, height: 108)
                            Circle()
                                .fill(MediaTheme.gold.opacity(0.1))
                                .frame(width: 82, height: 82)
                            Image(systemName: "lock.shield.fill")
                                .font(.largeTitle.weight(.regular))
                                .foregroundStyle(MediaTheme.gold)
                        }
                        .padding(.top, 36)

                        Text("影像内容已保护")
                            .font(.system(.title, design: .serif))
                            .foregroundStyle(MediaTheme.warmWhite)
                            .padding(.top, 28)

                        Text("受版权保护的影像不提供保存或分享\n录屏、投屏或 App 离开前台时将自动隐藏")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .lineSpacing(7)
                            .foregroundStyle(.white.opacity(0.58))
                            .padding(.top, 16)

                        Capsule()
                            .fill(MediaTheme.gold.opacity(0.7))
                            .frame(width: 32, height: 1)
                            .padding(.top, 28)

                        Text("PROTECTED CONTENT · YI SHU")
                            .font(.caption2.weight(.semibold))
                            .tracking(2.1)
                            .foregroundStyle(MediaTheme.muted)
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
            .stroke(MediaTheme.gold.opacity(0.035), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

private struct SceneCaptureStateObserver: UIViewRepresentable {
    let onChange: @MainActor (ScreenCaptureStatus) -> Void

    func makeUIView(context: Context) -> SceneCaptureStateObserverView {
        SceneCaptureStateObserverView(onChange: onChange)
    }

    func updateUIView(_ view: SceneCaptureStateObserverView, context: Context) {
        view.onChange = onChange
    }

    static func dismantleUIView(_ view: SceneCaptureStateObserverView, coordinator: Void) {
        view.stopObserving()
    }
}

@MainActor
private final class SceneCaptureStateObserverView: UIView {
    var onChange: @MainActor (ScreenCaptureStatus) -> Void
    private lazy var captureObserver = WindowCaptureObservation { [weak self] sample in
        self?.onChange(sample.status)
    }

    init(onChange: @escaping @MainActor (ScreenCaptureStatus) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        captureObserver.attach(to: window)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        captureObserver.attach(to: window)
    }

    func stopObserving() {
        captureObserver.attach(to: nil)
    }
}

/// Observes the real owning scene, not a nested secure UIHostingController's
/// transient traits. Synchronous callbacks are scoped to the current attachment.
@MainActor
final class WindowCaptureObservation: NSObject {
    private weak var observedWindow: UIWindow?
    private weak var observedScene: UIWindowScene?
    private weak var observedScreen: UIScreen?
    private var traitRegistration: (any UITraitChangeRegistration)?
    private var lastSample: ScreenCaptureSample?
    private let onChange: @MainActor (ScreenCaptureSample) -> Void

    init(onChange: @escaping @MainActor (ScreenCaptureSample) -> Void) {
        self.onChange = onChange
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        let scene = observedScene
        let registration = traitRegistration
        Task { @MainActor in
            if let registration { scene?.unregisterForTraitChanges(registration) }
        }
    }

    func attach(to window: UIWindow?) {
        guard observedWindow !== window || observedScene !== window?.windowScene ||
                observedScreen !== window?.windowScene?.screen else {
            resample()
            return
        }
        if let traitRegistration { observedScene?.unregisterForTraitChanges(traitRegistration) }
        traitRegistration = nil
        NotificationCenter.default.removeObserver(self)
        observedWindow = window
        observedScene = window?.windowScene
        observedScreen = window?.windowScene?.screen
        lastSample = nil
        guard let scene = observedScene else {
            publish(.detached)
            return
        }
        traitRegistration = scene.registerForTraitChanges([UITraitSceneCaptureState.self]) {
            [weak self] (source: UIWindowScene, _: UITraitCollection) in
            guard self?.observedScene === source else { return }
            self?.resample()
        }
        let center = NotificationCenter.default
        for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification,
                     UIScene.didEnterBackgroundNotification] {
            center.addObserver(self, selector: #selector(sceneChanged(_:)), name: name, object: scene)
        }
        center.addObserver(self, selector: #selector(sceneDisconnected(_:)),
                           name: UIScene.didDisconnectNotification, object: scene)
        center.addObserver(self, selector: #selector(screenChanged(_:)),
                           name: UIScreen.capturedDidChangeNotification, object: scene.screen)
        resample()
    }

    func resample() {
        guard let window = observedWindow else {
            publish(.detached)
            return
        }
        if window.windowScene !== observedScene || window.windowScene?.screen !== observedScreen {
            attach(to: window)
            return
        }
        guard let scene = observedScene else { publish(.detached); return }
        publish(ScreenCaptureSample(
            sceneStatus: ScreenCaptureStatus(scene.traitCollection.sceneCaptureState),
            screenIsCaptured: scene.screen.isCaptured,
            isAttached: true,
            isSceneActive: scene.activationState == .foregroundActive
        ))
    }

    @objc private func sceneChanged(_ notification: Notification) {
        guard let source = notification.object as? UIWindowScene, source === observedScene else { return }
        resample()
    }

    @objc private func screenChanged(_ notification: Notification) {
        guard let source = notification.object as? UIScreen, source === observedScene?.screen else { return }
        resample()
    }

    @objc private func sceneDisconnected(_ notification: Notification) {
        guard let source = notification.object as? UIWindowScene, source === observedScene else { return }
        attach(to: nil)
    }

    private func publish(_ sample: ScreenCaptureSample) {
        guard lastSample != sample else { return }
        lastSample = sample
        ScreenProtectionDiagnostics.record(sample: sample)
        onChange(sample)
    }
}

struct WindowLifecycleShieldState: Equatable {
    private(set) var hasEnteredActiveState = false
    private var lifecycleVisible = false
    private var captureStatus = ScreenCaptureStatus.unknown
    var captureNeedsCover: Bool { captureStatus != .inactive }
    var isVisible: Bool { lifecycleVisible || captureNeedsCover }

    mutating func updateCapture(_ status: ScreenCaptureStatus) {
        if status != .unknown { captureStatus = status }
    }

    mutating func sceneDidActivate() {
        hasEnteredActiveState = true
        lifecycleVisible = false
    }

    mutating func sceneWillDeactivate() {
        lifecycleVisible = hasEnteredActiveState
    }

    mutating func sceneDidEnterBackground() {
        lifecycleVisible = hasEnteredActiveState
    }

    mutating func reset() {
        self = WindowLifecycleShieldState()
    }
}

private struct WindowLifecycleProtectionInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> WindowLifecycleProtectionAttachmentView {
        WindowLifecycleProtectionAttachmentView()
    }

    func updateUIView(_ view: WindowLifecycleProtectionAttachmentView, context: Context) {
        view.refreshForcedState()
    }

    static func dismantleUIView(
        _ view: WindowLifecycleProtectionAttachmentView,
        coordinator: Void
    ) {
        view.detachFromProtectedWindow()
    }
}

/// Synchronous, scene-specific window shield, independent of the secure canvas.
/// Capture uses the same branded cover; inactive App Switcher snapshots retain
/// the existing black shield. System capture APIs are not a zero-frame DRM API.
@MainActor
final class WindowLifecycleProtectionAttachmentView: UIView {
    private weak var protectedWindow: UIWindow?
    private weak var observedScene: UIScene?
    private let shieldView = UIView(frame: .zero)
    private let shieldController = UIViewController()
    private var shieldWindow: UIWindow?
    private var lifecycleState = WindowLifecycleShieldState()
    private let captureCoverController = UIHostingController(rootView: CaptureProtectionCover())
    private lazy var captureObserver = WindowCaptureObservation { [weak self] sample in
        guard let self else { return }
        self.lifecycleState.updateCapture(sample.status)
        self.updateShieldVisibility()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false

        shieldView.backgroundColor = .black
        shieldView.isOpaque = true
        shieldView.isUserInteractionEnabled = true
        shieldView.isAccessibilityElement = true
        shieldView.accessibilityViewIsModal = true
        shieldView.accessibilityIdentifier = "window-lifecycle-protection-shield"
        shieldView.accessibilityLabel = "影像内容已保护"
        shieldController.view = shieldView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // UIKit temporarily removes the presenting view after a full-screen
        // presentation. Keep protecting its window until SwiftUI dismantles
        // this installer or the scene disconnects; nil here is not disposal.
        if let window { attach(to: window) }
    }

    func refreshForcedState() {
        attach(to: window ?? protectedWindow)
        captureObserver.resample()
        updateShieldVisibility()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        attach(to: window ?? protectedWindow)
    }

    func detachFromProtectedWindow() {
        NotificationCenter.default.removeObserver(self)
        protectedWindow = nil
        observedScene = nil
        captureObserver.attach(to: nil)
        removeCaptureCover()
        shieldWindow?.isHidden = true
        shieldWindow?.rootViewController = nil
        shieldWindow = nil
        lifecycleState.reset()
    }

    private func attach(to window: UIWindow?) {
        guard protectedWindow !== window || observedScene !== window?.windowScene else {
            captureObserver.attach(to: window)
            updateShieldVisibility()
            return
        }

        detachFromProtectedWindow()
        guard let window else { return }
        // A window can briefly lose its scene while the presenting view is
        // detached. Retain only the weak window binding so a later refresh can
        // reattach, without leaving a shield on the old scene.
        protectedWindow = window
        guard let scene = window.windowScene else { return }
        observedScene = scene

        // Sample first. Activating the scene must never clear capture protection.
        captureObserver.attach(to: window)

        if scene.activationState == .foregroundActive {
            lifecycleState.sceneDidActivate()
        }

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(sceneWillDeactivate(_:)),
            name: UIScene.willDeactivateNotification,
            object: scene
        )
        center.addObserver(
            self,
            selector: #selector(sceneDidEnterBackground(_:)),
            name: UIScene.didEnterBackgroundNotification,
            object: scene
        )
        center.addObserver(
            self,
            selector: #selector(sceneDidActivate(_:)),
            name: UIScene.didActivateNotification,
            object: scene
        )
        center.addObserver(
            self,
            selector: #selector(sceneDidDisconnect(_:)),
            name: UIScene.didDisconnectNotification,
            object: scene
        )
        updateShieldVisibility()
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene,
              scene === observedScene else { return }
        lifecycleState.sceneWillDeactivate()
        updateShieldVisibility()
    }

    @objc private func sceneDidEnterBackground(_ notification: Notification) {
        guard let scene = notification.object as? UIScene,
              scene === observedScene else { return }
        lifecycleState.sceneDidEnterBackground()
        updateShieldVisibility()
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene,
              scene === observedScene else { return }
        captureObserver.resample()
        lifecycleState.sceneDidActivate()
        updateShieldVisibility()
    }

    @objc private func sceneDidDisconnect(_ notification: Notification) {
        guard let scene = notification.object as? UIScene,
              scene === observedScene else { return }
        detachFromProtectedWindow()
    }

    private func updateShieldVisibility() {
        if lifecycleState.isVisible || ScreenProtectionTesting.forcesCover {
            installShieldIfNeeded()
        } else {
            removeCaptureCover()
            shieldWindow?.isHidden = true
            shieldWindow?.rootViewController = nil
            shieldWindow = nil
        }
    }

    private func installShieldIfNeeded() {
        guard let window = protectedWindow, let scene = window.windowScene else { return }
        if shieldWindow?.windowScene !== scene {
            removeCaptureCover()
            shieldWindow?.isHidden = true
            shieldWindow?.rootViewController = nil
            shieldWindow = nil
        }
        if shieldWindow == nil {
            let overlay = UIWindow(windowScene: scene)
            overlay.rootViewController = shieldController
            // Do not become key or change keyboard/focus ownership. A separate
            // app-owned window remains above same-scene full-screen modals.
            overlay.windowLevel = UIWindow.Level(rawValue: window.windowLevel.rawValue + 1)
            shieldWindow = overlay
        }
        shieldWindow?.frame = window.frame
        if lifecycleState.captureNeedsCover && !ScreenProtectionTesting.forcesCover {
            installCaptureCover()
        } else {
            removeCaptureCover()
        }
        shieldWindow?.isHidden = false
    }

    private func installCaptureCover() {
        let parent = shieldController
        if captureCoverController.parent !== parent {
            removeCaptureCover()
            parent.addChild(captureCoverController)
            captureCoverController.loadViewIfNeeded()
            guard let cover = captureCoverController.viewIfLoaded else {
                captureCoverController.removeFromParent()
                return
            }
            cover.frame = shieldView.bounds
            cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            shieldView.addSubview(cover)
            captureCoverController.didMove(toParent: parent)
        }
    }

    private func removeCaptureCover() {
        guard captureCoverController.parent != nil else { return }
        captureCoverController.willMove(toParent: nil)
        captureCoverController.viewIfLoaded?.removeFromSuperview()
        captureCoverController.removeFromParent()
    }
}

enum SecureCaptureSurfaceOwner: String, Equatable {
    case appRoot = "app_root"
    case fullScreenPresentation = "full_screen_presentation"
}

/// Installs one secure UIKit rendering surface for each independently composed
/// hierarchy. A full-screen presentation owns a separate UIKit hierarchy, so
/// it must explicitly request its own surface.
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

    @ViewBuilder
    var body: some View {
        if ScreenProtectionTesting.isDisabled {
            content
                .appAppearance(isAppRoot: owner == .appRoot)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack {
                // This ordinary layer is deliberately behind the secure
                // canvas. Static screenshots omit the secure descendants and
                // therefore reveal this branded privacy page instead of app
                // content. It never receives input or accessibility focus.
                CaptureProtectionCover()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                ScreenshotProtectedContent(owner: owner, onExit: onExit) {
                    content
                        .appAppearance(isAppRoot: owner == .appRoot)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .privacySensitive()
                }
                // The UIKit hosting surface must reach the window boundary;
                // otherwise descendants cannot paint outside its safe frame.
                // Its hosted SwiftUI content still receives UIKit safe insets.
                .ignoresSafeArea(.container)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Stay in the actual window's scene tree, outside the nested secure
            // UIHostingController. This also covers full-screen presentations.
            .protectedFromScreenCapture()
            .background {
                if owner == .appRoot {
                    WindowLifecycleProtectionInstaller()
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

struct ScreenshotProtectedContent: UIViewControllerRepresentable {
    let owner: SecureCaptureSurfaceOwner
    let content: AnyView
    let fallback: AnyView

    init<Content: View>(
        owner: SecureCaptureSurfaceOwner,
        onExit: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.owner = owner
        self.content = AnyView(content())
        fallback = AnyView(
            ScreenProtectionUnavailableView(owner: owner, onExit: onExit)
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(owner: owner)
    }

    func makeUIViewController(context: Context) -> SecureHostingContainerController {
        SecureHostingContainerController(
            rootView: AnyView(content.environment(\.appServiceEnvironment, context.environment.appServiceEnvironment)),
            fallbackView: fallback,
            stateObserver: context.coordinator.didTransition(to:)
        )
    }

    func updateUIViewController(
        _ controller: SecureHostingContainerController,
        context: Context
    ) {
        controller.update(rootView: AnyView(content.environment(\.appServiceEnvironment, context.environment.appServiceEnvironment)))
    }

    static func dismantleUIViewController(
        _ controller: SecureHostingContainerController,
        coordinator: Coordinator
    ) {
        controller.detachHostedContent()
    }

    final class Coordinator {
        private let owner: SecureCaptureSurfaceOwner

        init(owner: SecureCaptureSurfaceOwner) {
            self.owner = owner
        }

        func didTransition(to state: SecureCanvasInstallationState) {
            ScreenProtectionDiagnostics.record(state: state, owner: owner)
        }
    }
}

enum SecureCanvasFailureCode: Int, Equatable {
    case canvasMissing = 1
    case canvasNotAttached = 2
}

enum SecureCanvasInstallationState: Equatable {
    case probing(attempt: Int)
    case secured
    case privacyFallback(SecureCanvasFailureCode)
}

enum SecureCanvasFallbackPolicy {
    enum NextStep: Equatable {
        case retry
        case attachSecureCanvas
        case showPrivacyFallback(SecureCanvasFailureCode)
    }

    static func nextStep(
        attempt: Int,
        maximumAttempts: Int,
        failure: SecureCanvasFailureCode?
    ) -> NextStep {
        guard let failure else { return .attachSecureCanvas }
        return attempt < max(1, maximumAttempts)
            ? .retry
            : .showPrivacyFallback(failure)
    }
}

private enum SecureCanvasResolver {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cn.com.shuzijun.yishu",
        category: "ScreenProtection"
    )

    static func resolve(in textField: UITextField) -> UIView? {
        textField.setNeedsLayout()
        textField.layoutIfNeeded()

        let layerDelegates = (textField.layer.sublayers ?? [])
            .compactMap { $0.delegate as? UIView }
        let descendants = allDescendants(of: textField)

        let candidates = layerDelegates + descendants
        let selected = candidates.first { candidate in
            guard candidate !== textField,
                  candidate.isDescendant(of: textField) else {
                return false
            }
            // Avoid a hard-coded private UIKit class name. If the expected
            // secure layout host is absent, the container fails closed.
            return NSStringFromClass(type(of: candidate))
                .localizedCaseInsensitiveContains("canvas")
        }

#if DEBUG
        let hierarchy = descendants.map { view in
            "\(NSStringFromClass(type(of: view))){super=\(view.superview.map { NSStringFromClass(type(of: $0)) } ?? "nil")}"
        }.joined(separator: " > ")
        let layerClasses = layerDelegates
            .map { NSStringFromClass(type(of: $0)) }
            .joined(separator: ",")
        let selectedClass = selected.map { NSStringFromClass(type(of: $0)) } ?? "none"
        logger.debug(
            "Secure text hierarchy: descendants=\(hierarchy, privacy: .public) layerDelegates=\(layerClasses, privacy: .public) selected=\(selectedClass, privacy: .public)"
        )
#endif

        return selected
    }

    private static func allDescendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + allDescendants(of: $0) }
    }
}

@MainActor
final class SecureHostingContainerController: UIViewController {
    private let hostingController: UIHostingController<AnyView>
    private let secureContainerView: SecureHostingContainerView
    private var retriedAfterFirstLayout = false
    private var retriedAfterAppearance = false
    private var hasAttachedHostedContent = false

    init(
        rootView: AnyView,
        fallbackView: AnyView,
        maximumProbeAttempts: Int = 3,
        secureCanvasResolver: @escaping SecureHostingContainerView.CanvasResolver = SecureCanvasResolver.resolve(in:),
        stateObserver: @escaping (SecureCanvasInstallationState) -> Void = { _ in }
    ) {
        let hostingController = UIHostingController(rootView: fallbackView)
        self.hostingController = hostingController
        secureContainerView = SecureHostingContainerView(
            rootView: rootView,
            fallbackView: fallbackView,
            hostingController: hostingController,
            maximumProbeAttempts: maximumProbeAttempts,
            secureCanvasResolver: secureCanvasResolver,
            startsProbeImmediately: false,
            stateObserver: stateObserver
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        addChild(hostingController)
        view = secureContainerView
        secureContainerView.prepareHostedViewForContainment()
        hostingController.didMove(toParent: self)
        hasAttachedHostedContent = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !retriedAfterFirstLayout,
              case .privacyFallback = secureContainerView.installationState else {
            return
        }
        retriedAfterFirstLayout = true
        secureContainerView.beginLifecycleProbeCycle()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !retriedAfterAppearance,
              secureContainerView.installationState != .secured else {
            return
        }
        retriedAfterAppearance = true
        secureContainerView.beginLifecycleProbeCycle()
    }

    func update(rootView: AnyView) {
        secureContainerView.update(rootView: rootView)
    }

    func detachHostedContent() {
        guard hasAttachedHostedContent else { return }
        hostingController.willMove(toParent: nil)
        secureContainerView.detachHostedView()
        hostingController.removeFromParent()
        hasAttachedHostedContent = false
    }
}

@MainActor
final class SecureHostingContainerView: UIView {
    typealias CanvasResolver = (UITextField) -> UIView?

    private let secureTextField = NonFocusingSecureTextField(frame: .zero)
    private let hostingController: UIHostingController<AnyView>
    private let fallbackView: AnyView
    private let secureCanvasResolver: CanvasResolver
    private let maximumProbeAttempts: Int
    private let stateObserver: (SecureCanvasInstallationState) -> Void
    private var protectedRootView: AnyView
    private var hostedViewConstraints: [NSLayoutConstraint] = []
    private var probeAttempt = 0
    private var probeGeneration = 0
    private var hasPreparedHostedView = false
    private var hasStartedForCurrentWindowAttachment = false

    private(set) var installationState = SecureCanvasInstallationState.probing(attempt: 0)

    var hostsProtectedContent: Bool {
        installationState == .secured
            && hostingController.view.superview !== self
            && hostingController.view.superview != nil
    }

    var hostsVisiblePrivacyFallback: Bool {
        if case .privacyFallback = installationState {
            return hostingController.view.superview === self
        }
        return false
    }

    init(
        rootView: AnyView,
        fallbackView: AnyView = AnyView(ScreenProtectionUnavailableView(
            owner: .appRoot,
            onExit: nil
        )),
        maximumProbeAttempts: Int = 3,
        secureCanvasResolver: @escaping CanvasResolver = SecureCanvasResolver.resolve(in:),
        stateObserver: @escaping (SecureCanvasInstallationState) -> Void = { _ in }
    ) {
        let hostingController = UIHostingController(rootView: fallbackView)
        self.protectedRootView = rootView
        self.fallbackView = fallbackView
        self.maximumProbeAttempts = max(1, maximumProbeAttempts)
        self.secureCanvasResolver = secureCanvasResolver
        self.stateObserver = stateObserver
        self.hostingController = hostingController
        super.init(frame: .zero)
        configureContainer()
        prepareHostedViewForContainment()
        beginLifecycleProbeCycle()
    }

    init(
        rootView: AnyView,
        fallbackView: AnyView,
        hostingController: UIHostingController<AnyView>,
        maximumProbeAttempts: Int = 3,
        secureCanvasResolver: @escaping CanvasResolver = SecureCanvasResolver.resolve(in:),
        startsProbeImmediately: Bool,
        stateObserver: @escaping (SecureCanvasInstallationState) -> Void = { _ in }
    ) {
        protectedRootView = rootView
        self.fallbackView = fallbackView
        self.maximumProbeAttempts = max(1, maximumProbeAttempts)
        self.secureCanvasResolver = secureCanvasResolver
        self.stateObserver = stateObserver
        self.hostingController = hostingController
        super.init(frame: .zero)

        configureContainer()
        if startsProbeImmediately {
            prepareHostedViewForContainment()
            beginLifecycleProbeCycle()
        }
    }

    private func configureContainer() {
        // Keep every non-secure layer transparent so a screenshot exposes the
        // CaptureProtectionCover below this container, never a black rectangle.
        backgroundColor = .clear
        isOpaque = false
        secureTextField.isSecureTextEntry = true
        secureTextField.text = " "
        secureTextField.textColor = .clear
        secureTextField.tintColor = .clear
        secureTextField.backgroundColor = .clear
        secureTextField.isOpaque = false
        secureTextField.borderStyle = .none
        secureTextField.isAccessibilityElement = false
        secureTextField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(secureTextField)
        NSLayoutConstraint.activate([
            secureTextField.leadingAnchor.constraint(equalTo: leadingAnchor),
            secureTextField.trailingAnchor.constraint(equalTo: trailingAnchor),
            secureTextField.topAnchor.constraint(equalTo: topAnchor),
            secureTextField.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(rootView: AnyView) {
        protectedRootView = rootView
        guard installationState == .secured else {
            // Protected content is never assigned while the hosting view is
            // attached to the ordinary view hierarchy.
            hostingController.rootView = fallbackView
            return
        }
        hostingController.rootView = rootView
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            hasStartedForCurrentWindowAttachment = false
            return
        }
        guard !hasStartedForCurrentWindowAttachment,
              installationState != .secured else { return }
        hasStartedForCurrentWindowAttachment = true
        beginLifecycleProbeCycle()
    }

    func prepareHostedViewForContainment() {
        guard !hasPreparedHostedView else { return }
        hasPreparedHostedView = true
        let hostedView = hostingController.view!
        hostedView.backgroundColor = .clear
        hostedView.isOpaque = false
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        hostingController.rootView = fallbackView
        placeHostedView(in: self)
    }

    func beginLifecycleProbeCycle() {
        guard installationState != .secured else { return }
        prepareHostedViewForContainment()
        probeGeneration += 1
        probeAttempt = 0
        probeForSecureCanvas(generation: probeGeneration)
    }

    func detachHostedView() {
        probeGeneration += 1
        NSLayoutConstraint.deactivate(hostedViewConstraints)
        hostedViewConstraints.removeAll()
        hostingController.viewIfLoaded?.removeFromSuperview()
        hasPreparedHostedView = false
    }

    private func probeForSecureCanvas(generation: Int) {
        guard generation == probeGeneration,
              installationState != .secured else { return }
        probeAttempt += 1
        transition(to: .probing(attempt: probeAttempt))

        let secureCanvas = secureCanvasResolver(secureTextField)
        let failure: SecureCanvasFailureCode?
        if let secureCanvas {
            failure = secureCanvas !== secureTextField
                && secureCanvas.isDescendant(of: secureTextField)
                ? nil
                : .canvasNotAttached
        } else {
            failure = .canvasMissing
        }

        switch SecureCanvasFallbackPolicy.nextStep(
            attempt: probeAttempt,
            maximumAttempts: maximumProbeAttempts,
            failure: failure
        ) {
        case .attachSecureCanvas:
            guard let secureCanvas else {
                enterPrivacyFallback(.canvasMissing)
                return
            }
            hostingController.rootView = fallbackView
            placeHostedView(in: secureCanvas)
            hostingController.view.accessibilityViewIsModal = false
            hostingController.rootView = protectedRootView
            transition(to: .secured)

        case .retry:
            DispatchQueue.main.async { [weak self] in
                self?.probeForSecureCanvas(generation: generation)
            }

        case .showPrivacyFallback(let code):
            enterPrivacyFallback(code)
        }
    }

    private func enterPrivacyFallback(_ code: SecureCanvasFailureCode) {
        hostingController.rootView = fallbackView
        placeHostedView(in: self)
        hostingController.view.accessibilityViewIsModal = true
        transition(to: .privacyFallback(code))
    }

    private func placeHostedView(in container: UIView) {
        let hostedView = hostingController.view!
        NSLayoutConstraint.deactivate(hostedViewConstraints)
        hostedView.removeFromSuperview()
        container.addSubview(hostedView)
        hostedViewConstraints = [
            hostedView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostedView.topAnchor.constraint(equalTo: container.topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ]
        NSLayoutConstraint.activate(hostedViewConstraints)
    }

    private func transition(to state: SecureCanvasInstallationState) {
        guard installationState != state else { return }
        installationState = state
        stateObserver(state)
    }
}

private final class NonFocusingSecureTextField: UITextField {
    override var canBecomeFirstResponder: Bool {
        false
    }
}

private struct ScreenProtectionUnavailableView: View {
    let owner: SecureCaptureSurfaceOwner
    let onExit: (() -> Void)?

    var body: some View {
        ZStack {
            AppTheme.ink

            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.largeTitle.weight(.regular))
                    .foregroundStyle(AppTheme.gold)

                Text("安全显示暂不可用")
                    .font(.system(.title2, design: .serif))
                    .foregroundStyle(AppTheme.warmWhite)
                    .accessibilityAddTraits(.isHeader)

                Text("未能启用影像保护，受保护内容已隐藏。\n请关闭后重新打开此 APP。")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .lineSpacing(6)
                    .foregroundStyle(AppTheme.muted)

                if owner == .fullScreenPresentation, let onExit {
                    Button("关闭当前页面", action: onExit)
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.gold)
                        .foregroundStyle(AppTheme.ink)
                        .frame(minHeight: 44)
                        .padding(.top, 8)
                }
            }
            .padding(32)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen-protection-unavailable")
    }
}

private enum ScreenProtectionDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cn.com.shuzijun.yishu",
        category: "ScreenProtection"
    )

    static func record(sample: ScreenCaptureSample) {
        // Only enum values/booleans. Never include photo, URL, account, location,
        // device identifier or accessibility text in these local diagnostics.
        logger.info("Capture state: scene=\(sample.sceneStatus.rawValue, privacy: .public) screen=\(sample.screenIsCaptured, privacy: .public) attached=\(sample.isAttached, privacy: .public) foreground=\(sample.isSceneActive, privacy: .public) effective=\(sample.status.rawValue, privacy: .public)")
    }

    static func record(
        state: SecureCanvasInstallationState,
        owner: SecureCaptureSurfaceOwner
    ) {
        switch state {
        case .secured:
            logger.info(
                "Secure canvas installed: owner=\(owner.rawValue, privacy: .public)"
            )
        case .privacyFallback(let code):
            logger.fault(
                "Secure canvas unavailable; privacy fallback shown: owner=\(owner.rawValue, privacy: .public) code=\(code.rawValue, privacy: .public)"
            )
        case .probing:
            break
        }
    }
}

extension View {
    func protectedFromScreenCapture() -> some View {
        modifier(ScreenCaptureProtectionModifier())
    }
}
