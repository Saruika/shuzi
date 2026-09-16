import CryptoKit
import UIKit
import WebKit
import XCTest

/// Code-level, simulator-only WebKit integration against the actual App bundle.
/// This is NOT proof of the protected SwiftUI host, VoiceOver, physical-device
/// touch, or screenshot protection. It uses no App account/session, bypasses no
/// login, changes no capture setting, and never connects to a remote origin.
@MainActor
final class EmbeddedGameTests: XCTestCase {
    private let reviewedHashes = [
        "index.html": "9ae8f2895f5587bb6aa38e8d40c5d70ae9ee8768d215aad24750d4e879f98baa",
        "css/style.css": "5e89d4a6e7d741900d88c71e2839f3e00daf4b3811daa23c6f7ac2d48bba0a3b",
        "js/events.js": "df10acc91240a31e9ebe336a39aecfd55716a27f82d6a866394db6153261471e",
        "js/endings.js": "ae4f1173f961922e4bc72b65cca513fa5e633e3a5e93797d7e4c4fcfe9d960af",
        "js/main.js": "690c809e7d55b5a53991e31e6e8f06579e29d744dce56ccc6b1db807f350b797",
    ]

    func testAppBundleContainsExactlyReviewedOfflineGameResources() throws {
        let assets = try assetsDirectory()
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: assets, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ))
        var files: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            XCTAssertFalse(values.isSymbolicLink == true, "Game assets must not resolve outside the bundle")
            guard values.isRegularFile == true else { continue }
            let relative = String(url.path.dropFirst(assets.path.count + 1))
            files.append(relative)
            let data = try Data(contentsOf: url)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, reviewedHashes[relative], "Unreviewed bundled asset: \(relative)")
        }
        XCTAssertEqual(files.sorted(), reviewedHashes.keys.sorted())
    }

    func testOfflineResourceContractLoads108Questions432ChoicesAnd28Endings() async throws {
        let session = try await loadedSession()
        defer { session.close() }
        let catalog: GameCatalogSnapshot = try await session.json("""
        ({
          eventIDs: ALL_EVENTS.map(event => event.id),
          optionCounts: ALL_EVENTS.map(event => event.opts.length),
          endingIDs: ENDINGS.map(ending => ending.id),
          originIDs: ORIGINS.map(origin => origin.id),
          scripts: Array.from(document.scripts, script => new URL(script.src).pathname.split('/GameAssets/')[1]),
          styles: Array.from(document.querySelectorAll('link[rel="stylesheet"]'), link => new URL(link.href).pathname.split('/GameAssets/')[1]),
          loadedStyleSheets: document.styleSheets.length,
          csp: document.querySelector('meta[http-equiv="Content-Security-Policy"]').content,
          remoteResourceCount: performance.getEntriesByType('resource').filter(entry => !entry.name.startsWith('file:')).length
        })
        """)
        XCTAssertEqual(catalog.eventIDs, (1...108).map { String(format: "q%03d", $0) })
        XCTAssertEqual(catalog.optionCounts, Array(repeating: 4, count: 108))
        XCTAssertEqual(catalog.optionCounts.reduce(0, +), 432)
        XCTAssertEqual(catalog.endingIDs.count, 28)
        XCTAssertEqual(Set(catalog.endingIDs).count, 28)
        XCTAssertEqual(catalog.originIDs, ["peasant", "worker", "teacher", "official", "business", "soldier"])
        XCTAssertEqual(catalog.scripts, ["js/events.js", "js/endings.js", "js/main.js"])
        XCTAssertEqual(catalog.styles, ["css/style.css"])
        XCTAssertEqual(catalog.loadedStyleSheets, 1)
        for directive in ["default-src 'none'", "script-src 'self'", "connect-src 'none'", "frame-src 'none'", "form-action 'none'"] {
            XCTAssertTrue(catalog.csp.contains(directive), "Missing offline CSP: \(directive)")
        }
        XCTAssertEqual(catalog.remoteResourceCount, 0)
        XCTAssertFalse(session.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(session.navigation.violations.isEmpty, session.navigation.violations.joined(separator: ", "))
        XCTAssertEqual(session.navigation.finishedLoads, 1)
        // Navigation delegates do not observe arbitrary subresource requests.
        // The CSP + blocking content rules enforce offline access; the resource
        // timing check corroborates this run, not a packet-capture guarantee.
    }

    func testBaselineValuesForAllSixOrigins() async throws {
        let session = try await loadedSession()
        defer { session.close() }
        try await session.acceptDisclaimer()
        let origins: [(String, [Int])] = [
            ("peasant", [0, 0, 55, 90, 30, 0, 70, 0]),
            ("worker", [0, 1, 50, 90, 33, 2, 70, 0]),
            ("teacher", [0, 0, 50, 95, 30, 0, 75, 3]),
            ("official", [2, 5, 50, 90, 38, 0, 70, 0]),
            ("business", [3, 8, 50, 90, 35, 0, 70, 0]),
            ("soldier", [0, 0, 50, 100, 30, 3, 72, 0]),
        ]
        for (origin, expected) in origins {
            try await session.start(origin: origin)
            let snapshot: GameStateSnapshot = try await session.json(Self.stateExpression)
            XCTAssertEqual(snapshot.origin, origin)
            XCTAssertEqual(snapshot.stats, expected.map(Double.init), origin)
            XCTAssertEqual(snapshot.currentIdx, 0)
            XCTAssertEqual(snapshot.totalAnswered, 0)
            XCTAssertEqual(snapshot.flagCount, 0)
            XCTAssertFalse(snapshot.dead)
            XCTAssertNil(snapshot.ending)
            XCTAssertEqual(snapshot.activeScreen, "game")
            XCTAssertEqual(snapshot.questionID, "#001")
            XCTAssertEqual(snapshot.enabledOptionCount, 4)
        }
        XCTAssertTrue(session.navigation.violations.isEmpty, session.navigation.violations.joined(separator: ", "))
    }

    func testWhole108QuestionRouteUsesRealTimersAndReachesTopHuman() async throws {
        let session = try await loadedSession()
        defer { session.close() }
        try await session.acceptDisclaimer()
        try await session.start(origin: "peasant")
        let started = ContinuousClock.now
        for index in 0..<108 {
            let selected = index == 2 ? 1 : 0
            let clicked: Bool = try await session.json("""
            (() => {
              if (state.currentIdx !== \(index) || state.totalAnswered !== \(index) || state.dead) return false;
              const button = document.querySelectorAll('#options button')[\(selected)];
              if (!button || button.disabled || lifecyclePaused()) return false;
              button.click();
              return true;
            })()
            """)
            XCTAssertTrue(clicked, "Question \(index + 1) was not actually ready")
            guard clicked else { throw GameTestFailure.state("Choice rejected at \(index + 1)") }
            if index < 107 {
                let nextID = String(format: "#%03d", index + 2)
                try await session.waitFor("""
                state.currentIdx === \(index + 1) && state.totalAnswered === \(index + 1)
                  && !state.dead && document.getElementById('q-id').textContent === '\(nextID)'
                  && document.querySelectorAll('#options button:not(:disabled)').length === 4
                """, description: "Actual next-question timer after \(index + 1)", timeout: 4)
            }
            if index == 11 {
                let checkpoint: GameStateSnapshot = try await session.json(Self.stateExpression)
                XCTAssertEqual(Array(checkpoint.stats.prefix(6)), [2, 0, 75, 81, 25, 10])
            }
        }
        try await session.waitFor("state.dead && activeScreen === 'ending'", description: "Real settlement and ending timers", timeout: 5)
        let elapsed = started.duration(to: .now)
        XCTAssertGreaterThanOrEqual(elapsed, .seconds(38), "Do not replace or bypass the original 350/800/600 ms timers")
        let end: GameStateSnapshot = try await session.json(Self.stateExpression)
        XCTAssertEqual(end.totalAnswered, 108)
        XCTAssertEqual(end.currentIdx, 108)
        XCTAssertEqual(end.ending, "top_human")
        XCTAssertEqual(Array(end.stats.prefix(6)), [0, 0, 100, 80, 3, 86])
        XCTAssertTrue(end.dead)
        XCTAssertEqual(end.activeScreen, "ending")
        let displayed: [String] = try await session.json("Array.from(document.querySelectorAll('#ending-stats .ending-stat-val')).slice(0, 6).map(node => node.textContent)")
        XCTAssertEqual(displayed, ["0", "0", "100", "80", "3", "86"])
        XCTAssertTrue(session.navigation.violations.isEmpty, session.navigation.violations.joined(separator: ", "))
    }

    func testPortraitAndLandscapeDocumentCanScrollToLastChoice() async throws {
        let session = try await loadedSession()
        defer { session.close() }
        try await session.acceptDisclaimer()
        try await session.start(origin: "peasant")
        for size in [CGSize(width: 390, height: 780), CGSize(width: 844, height: 390), CGSize(width: 390, height: 780)] {
            session.resize(to: size)
            let landscape = size.width > size.height
            try await session.waitFor("(innerWidth > innerHeight) === \(landscape)",
                                      description: "Web viewport resized", timeout: 4)
            let requested: Bool = try await session.json("(() => { window.scrollTo({top: document.scrollingElement.scrollHeight, behavior: 'instant'}); return true; })()")
            XCTAssertTrue(requested)
            try await session.waitFor("""
            (() => {
              const scroll = document.scrollingElement;
              return scroll.scrollHeight <= innerHeight + 2 || window.scrollY > 0;
            })()
            """, description: "Document actually scrolled", timeout: 4)
            let metrics: GameScrollSnapshot = try await session.json("""
            (() => {
              const last = document.querySelector('#options button:last-child').getBoundingClientRect();
              return {
                scrollHeight: document.scrollingElement.scrollHeight,
                clientHeight: document.scrollingElement.clientHeight,
                viewportHeight: innerHeight, scrollY: window.scrollY,
                lastTop: last.top, lastBottom: last.bottom
              };
            })()
            """)
            XCTAssertGreaterThan(metrics.clientHeight, 0)
            XCTAssertGreaterThanOrEqual(metrics.scrollHeight + 2, metrics.clientHeight)
            XCTAssertGreaterThanOrEqual(metrics.lastTop, -2, "Last choice must not remain above the viewport")
            XCTAssertLessThanOrEqual(metrics.lastBottom, metrics.viewportHeight + 2, "Last choice must be fully reachable")
            if metrics.scrollHeight > metrics.viewportHeight + 2 {
                XCTAssertGreaterThan(metrics.scrollY, 0)
                // JavaScript completion observes the WebContent process, not
                // the later UIKit scrolling-tree commit. Wait only for that
                // native acknowledgement; never issue another scroll or set
                // contentOffset ourselves to make the assertion pass.
                let nativeDeadline = ContinuousClock.now.advanced(by: .seconds(4))
                while session.webView.scrollView.contentOffset.y <= 0 && ContinuousClock.now < nativeDeadline {
                    try await Task.sleep(for: .milliseconds(25))
                }
                XCTAssertGreaterThan(session.webView.scrollView.contentOffset.y, 0,
                    "Native WK scroll view must agree within 4s; viewport=\(size), JS scrollY=\(metrics.scrollY), native contentSize=\(session.webView.scrollView.contentSize)")
                XCTAssertGreaterThan(session.webView.scrollView.contentSize.height, session.webView.bounds.height)
            }
        }
        XCTAssertTrue(session.navigation.violations.isEmpty)
        // Programmatic scrolling is not proof of real drag or VoiceOver access.
    }

    private static let stateExpression = """
    ({
      origin: state.origin, stats: ['贪腐','财富','民心','健康','人脉','事业','廉洁','声望'].map(key => state[key]),
      currentIdx: state.currentIdx, totalAnswered: state.totalAnswered,
      flagCount: Object.keys(state.flags).length, dead: state.dead,
      ending: state.ending ? state.ending.id : null, activeScreen,
      questionID: document.getElementById('q-id').textContent,
      enabledOptionCount: document.querySelectorAll('#options button:not(:disabled)').length
    })
    """

    private func assetsDirectory() throws -> URL {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let assets = bundle.appendingPathComponent("GameAssets", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        XCTAssertTrue(assets.path.hasPrefix(bundle.path + "/"))
        guard FileManager.default.isReadableFile(atPath: assets.appendingPathComponent("index.html").path) else {
            throw GameTestFailure.state("Actual App bundle is missing GameAssets/index.html")
        }
        return assets
    }

    private func loadedSession() async throws -> GameWebKitSession {
#if targetEnvironment(simulator)
        let session = try GameWebKitSession(assets: assetsDirectory())
        do {
            try await session.load(test: self)
            return session
        } catch {
            session.close()
            throw error
        }
#else
        throw XCTSkip("Isolated game WebKit integration runs only on a simulator, never a user's installed App")
#endif
    }
}

private struct GameCatalogSnapshot: Decodable {
    let eventIDs: [String]
    let optionCounts: [Int]
    let endingIDs: [String]
    let originIDs: [String]
    let scripts: [String]
    let styles: [String]
    let loadedStyleSheets: Int
    let csp: String
    let remoteResourceCount: Int
}

private struct GameStateSnapshot: Decodable {
    let origin: String
    let stats: [Double]
    let currentIdx: Int
    let totalAnswered: Int
    let flagCount: Int
    let dead: Bool
    let ending: String?
    let activeScreen: String
    let questionID: String
    let enabledOptionCount: Int
}

private struct GameScrollSnapshot: Decodable {
    let scrollHeight: Double
    let clientHeight: Double
    let viewportHeight: Double
    let scrollY: Double
    let lastTop: Double
    let lastBottom: Double
}

private enum GameTestFailure: Error {
    case state(String)
}

@MainActor
private final class GameWebKitSession {
    let webView: WKWebView
    let navigation: GameOfflineNavigation
    private let assets: URL
    private let window: UIWindow

    init(assets: URL) throws {
        self.assets = assets
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }), "A foreground simulator scene is required")
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 780)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.dataDetectorTypes = []
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: .zero, configuration: configuration)
        navigation = GameOfflineNavigation(assets: assets)
        webView.navigationDelegate = navigation
        webView.uiDelegate = navigation
        webView.isInspectable = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        let controller = UIViewController()
        controller.view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: controller.view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
        ])
        // Only a local game document is attached. Never make this the key window
        // or alter a real App window, authentication, or capture protection.
        window.rootViewController = controller
        window.isHidden = false
        controller.view.layoutIfNeeded()
    }

    func load(test: XCTestCase) async throws {
        let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^file://"},"action":{"type":"ignore-previous-rules"}}]"#
        let list: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "cn.com.shuzijun.yishu.tests.game.offline.v1", encodedContentRuleList: rules
            ) { list, error in
                if let error { continuation.resume(throwing: error) }
                else if let list { continuation.resume(returning: list) }
                else { continuation.resume(throwing: GameTestFailure.state("Offline content rules unavailable")) }
            }
        }
        webView.configuration.userContentController.add(list)
        webView.loadFileURL(assets.appendingPathComponent("index.html"), allowingReadAccessTo: assets)
        await test.fulfillment(of: [navigation.loaded], timeout: 20)
        guard navigation.didFinish, navigation.violations.isEmpty else {
            throw GameTestFailure.state("Local load did not complete cleanly: \(navigation.violations)")
        }
        try await waitFor("document.readyState === 'complete' && typeof ALL_EVENTS !== 'undefined' && !document.hidden",
                          description: "Real visible WebKit document", timeout: 5)
    }

    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        window.isHidden = true
        window.rootViewController = nil
    }

    func resize(to size: CGSize) {
        window.frame = CGRect(origin: .zero, size: size)
        window.setNeedsLayout()
        window.layoutIfNeeded()
        window.rootViewController?.view.setNeedsLayout()
        window.rootViewController?.view.layoutIfNeeded()
        webView.layoutIfNeeded()
    }

    func json<Value: Decodable>(_ expression: String) async throws -> Value {
        let text: String = try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript("JSON.stringify(\(expression))") { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let text = value as? String { continuation.resume(returning: text) }
                else { continuation.resume(throwing: GameTestFailure.state("JavaScript did not return JSON")) }
            }
        }
        return try JSONDecoder().decode(Value.self, from: Data(text.utf8))
    }

    func waitFor(_ expression: String, description: String, timeout: TimeInterval) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            let ready: Bool = try await json("Boolean(\(expression))")
            if ready { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw GameTestFailure.state("Timed out waiting for \(description)")
    }

    func acceptDisclaimer() async throws {
        try await waitFor("!document.getElementById('btn-accept').disabled", description: "Original five-second disclaimer", timeout: 9)
        let accepted: Bool = try await json("(() => { document.getElementById('btn-accept').click(); return disclaimerAccepted && !document.getElementById('disclaimer'); })()")
        XCTAssertTrue(accepted)
    }

    func start(origin: String) async throws {
        // The caller supplies one of the six fixed test identifiers, never user input.
        let started: Bool = try await json("""
        (() => {
          returnToIntro();
          const origin = document.querySelector('#origin-list button[data-id="\(origin)"]');
          if (!origin) return false;
          origin.click();
          document.getElementById('btn-start').click();
          return gameStarted && activeScreen === 'game';
        })()
        """)
        XCTAssertTrue(started, origin)
        guard started else { throw GameTestFailure.state("Original start handler rejected \(origin)") }
    }
}

@MainActor
private final class GameOfflineNavigation: NSObject, WKNavigationDelegate, WKUIDelegate {
    let loaded = XCTestExpectation(description: "Bundled game loadFileURL completed")
    private let assets: URL
    private var completed = false
    private(set) var didFinish = false
    private(set) var finishedLoads = 0
    private(set) var violations: [String] = []

    init(assets: URL) { self.assets = assets }

    private func permits(_ url: URL?) -> Bool {
        guard let url, url.isFileURL else { return false }
        return url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(assets.path + "/")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.targetFrame?.isMainFrame == true, !action.shouldPerformDownload, permits(action.request.url) else {
            violations.append("Nonlocal navigation, new window, subframe, or download attempted")
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard permits(response.response.url), response.canShowMIMEType else {
            violations.append("Nonlocal or unrenderable navigation response")
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish = true
        finishedLoads += 1
        complete()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        violations.append("WebKit content process terminated")
        complete()
    }

    private func failed(_ error: Error) {
        let error = error as NSError
        violations.append("Load failed: \(error.domain) / \(error.code)")
        complete()
    }

    private func complete() {
        guard !completed else { return }
        completed = true
        loaded.fulfill()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        violations.append("Popup requested")
        return nil
    }
}
