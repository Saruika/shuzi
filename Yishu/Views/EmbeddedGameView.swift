import SwiftUI
import UIKit
import WebKit

/// Offline host for the authorized, bundled game resources.
/// The caller must present this inside its existing SecureCaptureSurface.
/// The game document receives no account/session values or remote access.
/// One bounded result-only bridge prepares a run for voluntary native submission.
struct EmbeddedGameView: View {
    @ObservedObject private var account: FanAccountStore
    @StateObject private var leaderboard = GameLeaderboardStore()
    private let onClose: () -> Void
    @State private var loadState = EmbeddedGameLoadState.loading
    @State private var attempt = 0
    @State private var showsExitConfirmation = false
    @State private var showsLeaderboard = false

    init(account: FanAccountStore, onClose: @escaping () -> Void) {
        self.account = account
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("宦海浮沉录")
                        .font(.headline)
                    Text("离线游玩 · 进度仅保留本局")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("embedded-game-heading")
                Spacer(minLength: 8)
                Button { showsLeaderboard = true } label: {
                    Image(systemName: leaderboard.preparedRun == nil ? "trophy" : "trophy.fill")
                        .font(.body.weight(.medium))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(leaderboard.preparedRun == nil ? "排行榜" : "排行榜，可提交最近完成的成绩")
                .accessibilityIdentifier("embedded-game-leaderboard")
                Button { showsExitConfirmation = true } label: {
                    Label("关闭", systemImage: "xmark")
                        .font(.body.weight(.medium))
                        .frame(minWidth: 64, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭游戏")
                .accessibilityIdentifier("embedded-game-close")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(.white)
            // Match the light system status-bar text with the native header;
            // the game's paper-colored canvas starts below this header.
            .background(Color(red: 38.0 / 255, green: 38.0 / 255, blue: 34.0 / 255)
                .ignoresSafeArea(edges: .top))
            Divider()
            ZStack {
                EmbeddedGameWebView(loadState: $loadState) { [expected = account.gameLeaderboardContext] payload in
                    guard expected != nil, account.gameLeaderboardContext == expected else { return }
                    _ = leaderboard.prepare(payload, using: account)
                }
                    .id(attempt)
                switch loadState {
                case .loading:
                    ProgressView("正在载入本地游戏…")
                        .tint(Color(red: 38.0 / 255, green: 38.0 / 255, blue: 34.0 / 255))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(red: 246.0 / 255, green: 245.0 / 255, blue: 240.0 / 255))
                        .accessibilityIdentifier("embedded-game-loading")
                case .ready:
                    EmptyView()
                case .failed(let message):
                    ContentUnavailableView {
                        Label("游戏暂时无法打开", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("重新载入") {
                            leaderboard.discardPreparedRun()
                            loadState = .loading
                            attempt += 1
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("embedded-game-retry")
                    }
                    .background(Color(red: 246.0 / 255, green: 245.0 / 255, blue: 240.0 / 255))
                    .accessibilityIdentifier("embedded-game-error")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.colorScheme, .light)
        }
        // Only the backdrop ignores safe areas. Native controls and the WebView
        // remain separate layout regions, including in landscape and on iPad.
        .foregroundStyle(Color(red: 38.0 / 255, green: 38.0 / 255, blue: 34.0 / 255))
        .background(Color(red: 246.0 / 255, green: 245.0 / 255, blue: 240.0 / 255).ignoresSafeArea())
        // Only this presentation uses a dark native/status-bar header. The
        // game canvas stays explicitly light; no stored App theme is changed.
        .preferredColorScheme(.dark)
        .onAppear { leaderboard.updateContext(account.gameLeaderboardContext) }
        .onChange(of: account.gameLeaderboardContext) { _, context in
            leaderboard.updateContext(context)
            showsLeaderboard = false
            // A run begun by a previous login cannot become the next user's run.
            loadState = .loading
            attempt += 1
        }
        .sheet(isPresented: $showsLeaderboard) {
            SecureCaptureSurface(owner: .fullScreenPresentation, onExit: { showsLeaderboard = false }) {
                GameLeaderboardView(account: account, store: leaderboard, onClose: { showsLeaderboard = false })
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .alert("离开游戏？", isPresented: $showsExitConfirmation) {
            Button("继续游戏", role: .cancel) {}
                .accessibilityIdentifier("embedded-game-continue")
            Button("关闭游戏", role: .destructive) { onClose() }
                .accessibilityIdentifier("embedded-game-confirm-close")
        } message: {
            Text("离开会结束本局。确认关闭游戏吗？")
        }
    }
}

/// WKUserContentController retains handlers. The proxy must not retain the host.
@MainActor
private final class WeakGameResultHandler: NSObject, WKScriptMessageHandler {
    private weak var coordinator: EmbeddedGameWebView.Coordinator?
    init(_ coordinator: EmbeddedGameWebView.Coordinator) { self.coordinator = coordinator }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        coordinator?.receive(message)
    }
}

enum EmbeddedGameLoadState: Equatable {
    case loading
    case ready
    case failed(String)
}

struct EmbeddedGameWebView: UIViewRepresentable {
    @Binding var loadState: EmbeddedGameLoadState
    let onRunCompleted: (GameRunPayload) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(loadState: $loadState, onRunCompleted: onRunCompleted) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.dataDetectorTypes = []
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.add(WeakGameResultHandler(context.coordinator), name: "gameLeaderboard")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isInspectable = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        // WKWebView must remain an accessibility container, not one synthetic
        // element. Manage loading state natively so SwiftUI does not cache an
        // inaccessible representable while WebKit's remote tree is created.
        webView.isAccessibilityElement = false
        webView.accessibilityElementsHidden = true
        webView.isUserInteractionEnabled = false
        webView.accessibilityIdentifier = "embedded-game-webview"
        context.coordinator.start(in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.updatePresentation(in: webView, state: loadState)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.invalidate()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "gameLeaderboard")
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let loadState: Binding<EmbeddedGameLoadState>
        private var assetsDirectory: URL?
        private var loadTimeout: Task<Void, Never>?
        private var isValid = true
        private var hasFailed = false
        private var isContentAccessible = false
        private weak var hostedWebView: WKWebView?
        private var indexURL: URL?
        private let onRunCompleted: (GameRunPayload) -> Void

        init(loadState: Binding<EmbeddedGameLoadState>, onRunCompleted: @escaping (GameRunPayload) -> Void) {
            self.loadState = loadState
            self.onRunCompleted = onRunCompleted
        }

        func receive(_ message: WKScriptMessage) {
            guard isValid, !hasFailed, isContentAccessible,
                  message.name == "gameLeaderboard", message.frameInfo.isMainFrame,
                  message.webView === hostedWebView,
                  let url = message.frameInfo.request.url, url.isFileURL,
                  url.resolvingSymlinksInPath().standardizedFileURL == indexURL,
                  let body = message.body as? [String: Any],
                  Set(body.keys) == Set(["origin", "choices"]),
                  let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 2048,
                  let payload = try? JSONDecoder().decode(GameRunPayload.self, from: data) else { return }
            // No automatic network request, identity injection, or JS score trust.
            onRunCompleted(payload)
        }

        func updatePresentation(in webView: WKWebView, state: EmbeddedGameLoadState) {
            let isReady = state == .ready
            webView.isUserInteractionEnabled = isReady
            webView.accessibilityElementsHidden = !isReady
            guard isContentAccessible != isReady else { return }
            isContentAccessible = isReady
            guard isReady else { return }
            // Announce the newly exposed document after the loading overlay
            // has left the SwiftUI tree, without moving focus to the whole
            // WebView or inspecting/injecting any game state.
            DispatchQueue.main.async { [weak self, weak webView] in
                guard let self, self.isValid, self.isContentAccessible,
                      let webView, webView.window != nil else { return }
                UIAccessibility.post(notification: .layoutChanged, argument: nil)
            }
        }

        func start(in webView: WKWebView) {
            armTimeout(for: webView)
            let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
            let assets = bundle.appendingPathComponent("GameAssets", isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL
            let index = assets.appendingPathComponent("index.html")
                .resolvingSymlinksInPath().standardizedFileURL
            guard assets.path.hasPrefix(bundle.path + "/"),
                  index.path.hasPrefix(assets.path + "/"),
                  FileManager.default.isReadableFile(atPath: index.path) else {
                fail("本地游戏资源不完整。请关闭游戏并联系技术支持，不影响其他 App 功能。")
                return
            }
            assetsDirectory = assets
            indexURL = index
            hostedWebView = webView

            // Only local bundle assets are permitted. No remote scripts,
            // styles, analytics, fetches, frames or downloads are needed here.
            // The file-read sandbox below independently restricts local access.
            let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^file://"},"action":{"type":"ignore-previous-rules"}}]"#
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "cn.com.shuzijun.yishu.game.offline.v1",
                encodedContentRuleList: rules
            ) { [weak self, weak webView] list, _ in
                guard let self, self.isValid, !self.hasFailed, let webView else { return }
                guard let list else {
                    self.fail("本地访问限制初始化失败。可以重新载入，不会改动游戏以外的页面或账号。")
                    return
                }
                webView.configuration.userContentController.add(list)
                webView.loadFileURL(index, allowingReadAccessTo: assets)
            }
        }

        func invalidate() {
            isValid = false
            loadTimeout?.cancel()
            loadTimeout = nil
        }

        private func permits(_ url: URL?) -> Bool {
            guard let url, url.isFileURL, let assetsDirectory else { return false }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            return resolved.path.hasPrefix(assetsDirectory.path + "/")
        }

        private func publish(_ state: EmbeddedGameLoadState) {
            // Avoid changing SwiftUI state synchronously inside makeUIView.
            Task { @MainActor [weak self] in
                guard let self, self.isValid else { return }
                if self.hasFailed {
                    guard case .failed = state else { return }
                }
                self.loadState.wrappedValue = state
            }
        }

        private func fail(_ message: String) {
            guard isValid, !hasFailed else { return }
            hasFailed = true
            loadTimeout?.cancel()
            loadTimeout = nil
            publish(.failed(message))
        }

        private func armTimeout(for webView: WKWebView) {
            loadTimeout?.cancel()
            loadTimeout = Task { @MainActor [weak self, weak webView] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard !Task.isCancelled, let self, self.isValid, !self.hasFailed else { return }
                self.fail("本地资源加载超时。请重新载入，或关闭游戏后重试。")
                webView?.stopLoading()
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard isValid, !hasFailed, action.targetFrame?.isMainFrame == true,
                  !action.shouldPerformDownload, permits(action.request.url) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(isValid && !hasFailed && permits(response.response.url)
                && response.canShowMIMEType ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard isValid, !hasFailed else { return }
            publish(.loading)
            armTimeout(for: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard isValid, !hasFailed else { return }
            loadTimeout?.cancel()
            loadTimeout = nil
            publish(.ready)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            navigationFailed(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            navigationFailed(error)
        }

        private func navigationFailed(_ error: Error) {
            let issue = error as NSError
            guard !(issue.domain == NSURLErrorDomain && issue.code == NSURLErrorCancelled) else { return }
            fail("本地游戏页面加载失败。请重新载入；若仍失败，需要检查打包资源。")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            fail("游戏进程已停止。重新载入将开始新的一局，不会退出 App 账号。")
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            nil
        }

        func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                     completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
            completionHandler(nil)
        }
    }
}
