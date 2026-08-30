import AVFoundation
import ImageIO
import SwiftUI
import UIKit

private enum ArtworkImageLoadError: Error {
    case invalidResponse
    case payloadTooLarge
    case decodeFailed
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
        requestTimeout: 20,
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
        let task = Task.detached(priority: .utility) {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 20
            request.setValue(
                "image/avif,image/webp,image/heic,image/heif,image/jpeg,image/png",
                forHTTPHeaderField: "Accept"
            )
            request.setValue("Yishu-iOS/2.1", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await imageSession.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  ContentSecurityPolicy.matchesRequestedMediaURL(http.url, requestedURL: url),
                  (200..<300).contains(http.statusCode) else {
                throw ArtworkImageLoadError.invalidResponse
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
    @State private var image: UIImage?
    @State private var error: Error?

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
        return "\(url.absoluteString)#\(maxPixelSize)"
    }

    var body: some View {
        // Keep the loading task attached even when a caller intentionally
        // renders no placeholder for the `.empty` phase.
        ZStack {
            content(phase)
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
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(2.2)
                    .foregroundStyle(AppTheme.gold)
                Text(title)
                    .font(.editorial(30))
                    .foregroundStyle(AppTheme.warmWhite)
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
            .font(.system(size: 10, weight: .medium))
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
    @State private var isCaptureActive = false
    @State private var hasEnteredActiveState = false
    @State private var isPrivacyCoverVisible = false
    @State private var isScreenshotWarningVisible = false
    @State private var screenshotWarningTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        ZStack {
            content

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
        withAnimation(.easeOut(duration: 0.12)) {
            isScreenshotWarningVisible = true
        }
        screenshotWarningTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled, scenePhase == .active, !isCaptureActive else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                isScreenshotWarningVisible = false
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

            VStack(spacing: 0) {
                Text("狐狸姐姐温馨提示")
                    .font(.system(size: 12, weight: .semibold))
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
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(AppTheme.gold)
                }
                .padding(.top, 36)

                Text("影像内容已保护")
                    .font(.editorial(31))
                    .foregroundStyle(AppTheme.warmWhite)
                    .padding(.top, 28)

                Text("为尊重肖像权与作品版权\n此 APP 不支持截屏、录屏或保存")
                    .font(.system(size: 13, weight: .regular))
                    .multilineTextAlignment(.center)
                    .lineSpacing(7)
                    .foregroundStyle(.white.opacity(0.58))
                    .padding(.top, 16)

                Capsule()
                    .fill(AppTheme.gold.opacity(0.7))
                    .frame(width: 32, height: 1)
                    .padding(.top, 28)

                Text("PROTECTED CONTENT · YI SHU")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(2.1)
                    .foregroundStyle(.white.opacity(0.28))
                    .padding(.top, 18)
            }
            .padding(.horizontal, 30)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("狐狸姐姐温馨提示：影像内容已保护，此 APP 不支持截屏、录屏或保存")
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

struct ScreenshotProtectedContent: UIViewRepresentable {
    let content: AnyView

    init<Content: View>(@ViewBuilder content: () -> Content) {
        self.content = AnyView(content())
    }

    func makeUIView(context: Context) -> SecureHostingContainerView {
        SecureHostingContainerView(rootView: content)
    }

    func updateUIView(_ view: SecureHostingContainerView, context: Context) {
        view.update(rootView: content)
    }
}

final class SecureHostingContainerView: UIView {
    private let secureTextField = NonFocusingSecureTextField(frame: .zero)
    private let hostingController: UIHostingController<AnyView>

    init(rootView: AnyView) {
        hostingController = UIHostingController(rootView: rootView)
        super.init(frame: .zero)

        backgroundColor = .black
        secureTextField.isSecureTextEntry = true
        secureTextField.text = " "
        secureTextField.textColor = .clear
        secureTextField.tintColor = .clear
        secureTextField.backgroundColor = .clear
        secureTextField.borderStyle = .none
        secureTextField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(secureTextField)
        NSLayoutConstraint.activate([
            secureTextField.leadingAnchor.constraint(equalTo: leadingAnchor),
            secureTextField.trailingAnchor.constraint(equalTo: trailingAnchor),
            secureTextField.topAnchor.constraint(equalTo: topAnchor),
            secureTextField.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // The secure canvas must remain inside its text field. Detaching and
        // returning the canvas loses capture protection on newer iOS versions.
        secureTextField.layoutIfNeeded()
        guard let secureCanvas = secureTextField.layer.sublayers?.first?.delegate as? UIView else {
            // Fail closed if UIKit changes its secure rendering hierarchy.
            return
        }

        let hostedView = hostingController.view!
        hostedView.backgroundColor = .clear
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        secureCanvas.addSubview(hostedView)
        NSLayoutConstraint.activate([
            hostedView.leadingAnchor.constraint(equalTo: secureCanvas.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: secureCanvas.trailingAnchor),
            hostedView.topAnchor.constraint(equalTo: secureCanvas.topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: secureCanvas.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(rootView: AnyView) {
        hostingController.rootView = rootView
    }
}

private final class NonFocusingSecureTextField: UITextField {
    override var canBecomeFirstResponder: Bool {
        false
    }
}

extension View {
    func protectedFromScreenCapture() -> some View {
        modifier(ScreenCaptureProtectionModifier())
    }
}
