import AVFoundation
import ImageIO
import OSLog
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
    private var inFlight: [String: Task<UIImage, Error>] = [:]
    private let session = SecureURLSessionFactory.make(
        requestTimeout: 8,
        resourceTimeout: 30
    )

    func image(for url: URL, maxPixelSize: Int) async throws -> UIImage {
        guard ContentSecurityPolicy.isTrustedMediaURL(url) else {
            throw ArtworkImageLoadError.invalidResponse
        }
        let bucket = min(2_200, max(320, ((maxPixelSize + 159) / 160) * 160))
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

struct DownsampledAsyncImage<Content: View>: View {
    let url: URL?
    let targetSize: CGSize
    var maximumPixelSize: Int = 2_200
    let content: (AsyncImagePhase) -> Content

    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @State private var image: UIImage?
    @State private var error: Error?
    @State private var retryGeneration = 0

    init(
        url: URL?,
        targetSize: CGSize,
        maximumPixelSize: Int = 2_200,
        @ViewBuilder content: @escaping (AsyncImagePhase) -> Content
    ) {
        self.url = url
        self.targetSize = targetSize
        self.maximumPixelSize = maximumPixelSize
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

            if error != nil {
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
            image = nil
            error = nil
            guard let url, maxPixelSize > 0 else { return }
            do {
                let loaded = try await ArtworkImagePipeline.shared.image(
                    for: url,
                    maxPixelSize: maxPixelSize
                )
                guard !Task.isCancelled else { return }
                image = loaded
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, error != nil else { return }
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
                // VoiceOver rotor. This changes accessibility exposure only;
                // the secure rendering hierarchy remains unchanged.
                .accessibilityHidden(shouldShowProtectionCover)
                .allowsHitTesting(!shouldShowProtectionCover)

            if shouldShowProtectionCover {
                CaptureProtectionCover()
                    .zIndex(10_000)
                    .transition(.opacity)
            }
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
        let sceneIsCaptured = windowScenes
            .contains { $0.traitCollection.sceneCaptureState == .active }
        let screenIsCaptured = windowScenes.map(\.screen).contains(where: \.isCaptured)
        isCaptureActive = sceneIsCaptured || screenIsCaptured
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

                        Text("为尊重肖像权与作品版权\n此 APP 不支持截屏、录屏或保存")
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
                            .foregroundStyle(.white.opacity(0.28))
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
        .accessibilityLabel("狐狸姐姐温馨提示：影像内容已保护，此 APP 不支持截屏、录屏或保存")
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

enum SecureCaptureSurfaceOwner: String, Equatable {
    case appRoot = "app_root"
    case fullScreenPresentation = "full_screen_presentation"
}

/// Installs exactly one secure UIKit rendering surface for an independently
/// composed hierarchy. A full-screen cover is a new UIKit presentation
/// hierarchy even when it inherits SwiftUI environment values, so its owner
/// must explicitly request a new surface.
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
        } else {
            ScreenshotProtectedContent(owner: owner, onExit: onExit) {
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ScreenshotProtectedContent: UIViewRepresentable {
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

    func makeUIView(context: Context) -> SecureHostingContainerView {
        SecureHostingContainerView(
            rootView: content,
            fallbackView: fallback,
            stateObserver: context.coordinator.didTransition(to:)
        )
    }

    func updateUIView(_ view: SecureHostingContainerView, context: Context) {
        view.update(rootView: content)
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
    static func resolve(in textField: UITextField) -> UIView? {
        textField.setNeedsLayout()
        textField.layoutIfNeeded()

        let layerDelegates = (textField.layer.sublayers ?? [])
            .compactMap { $0.delegate as? UIView }
        let descendants = allDescendants(of: textField)

        return (layerDelegates + descendants).first { candidate in
            guard candidate !== textField,
                  candidate.isDescendant(of: textField) else {
                return false
            }
            // UIKit's private class name has changed between releases, but the
            // secure text layout host has consistently remained a canvas view.
            // If that invariant changes, fail closed instead of guessing at an
            // arbitrary subview that might be captured.
            return NSStringFromClass(type(of: candidate))
                .localizedCaseInsensitiveContains("canvas")
        }
    }

    private static func allDescendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + allDescendants(of: $0) }
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
        protectedRootView = rootView
        self.fallbackView = fallbackView
        self.maximumProbeAttempts = max(1, maximumProbeAttempts)
        self.secureCanvasResolver = secureCanvasResolver
        self.stateObserver = stateObserver
        hostingController = UIHostingController(rootView: fallbackView)
        super.init(frame: .zero)

        backgroundColor = .black
        isOpaque = true
        secureTextField.isSecureTextEntry = true
        secureTextField.text = " "
        secureTextField.textColor = .clear
        secureTextField.tintColor = .clear
        secureTextField.backgroundColor = .clear
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

        let hostedView = hostingController.view!
        hostedView.backgroundColor = .black
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        placeHostedView(in: self)
        probeForSecureCanvas()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(rootView: AnyView) {
        protectedRootView = rootView
        guard installationState == .secured else {
            // Never replace the non-sensitive fallback with protected content
            // while the hosting view is attached to the ordinary view tree.
            hostingController.rootView = fallbackView
            return
        }
        hostingController.rootView = rootView
    }

    private func probeForSecureCanvas() {
        guard installationState != .secured else { return }
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
            // Keep the fallback root while moving the hosted view. Protected
            // content is assigned only after it is inside the secure canvas.
            hostingController.rootView = fallbackView
            placeHostedView(in: secureCanvas)
            hostingController.view.accessibilityViewIsModal = false
            hostingController.rootView = protectedRootView
            transition(to: .secured)

        case .retry:
            // The secure canvas may not exist until UIKit finishes its first
            // layout pass. The fallback stays visible while retrying.
            DispatchQueue.main.async { [weak self] in
                self?.probeForSecureCanvas()
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
                    .foregroundStyle(.white.opacity(0.66))

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
