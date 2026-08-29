import AVFoundation
import SwiftUI
import UIKit

struct ArtworkImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    var body: some View {
        GeometryReader { proxy in
            AsyncImage(
                url: url,
                transaction: Transaction(animation: .easeOut(duration: 0.35))
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
                Text("易 姝")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(6)
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

                Text("为尊重肖像权与作品版权\n此页面不支持截屏、录屏或保存")
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
        .accessibilityLabel("易姝影像内容已保护，此页面不支持截屏、录屏或保存")
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

    func makeCoordinator() -> Coordinator {
        Coordinator(rootView: content)
    }

    func makeUIView(context: Context) -> UIView {
        let secureTextField = UITextField(frame: .zero)
        secureTextField.isSecureTextEntry = true
        secureTextField.text = " "
        secureTextField.textColor = .clear
        secureTextField.tintColor = .clear
        secureTextField.backgroundColor = .clear
        secureTextField.layoutIfNeeded()

        guard let secureCanvas = secureTextField.layer.sublayers?.first?.delegate as? UIView else {
            return context.coordinator.hostingController.view
        }

        secureCanvas.subviews.forEach { $0.removeFromSuperview() }
        let hostedView = context.coordinator.hostingController.view!
        hostedView.backgroundColor = .clear
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        secureCanvas.addSubview(hostedView)
        NSLayoutConstraint.activate([
            hostedView.leadingAnchor.constraint(equalTo: secureCanvas.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: secureCanvas.trailingAnchor),
            hostedView.topAnchor.constraint(equalTo: secureCanvas.topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: secureCanvas.bottomAnchor)
        ])
        return secureCanvas
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.hostingController.rootView = content
    }

    final class Coordinator {
        let hostingController: UIHostingController<AnyView>

        init(rootView: AnyView) {
            hostingController = UIHostingController(rootView: rootView)
        }
    }
}

extension View {
    func protectedFromScreenCapture() -> some View {
        modifier(ScreenCaptureProtectionModifier())
    }
}
