import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Yishu

/// Simulator-only integration of the real UIViewRepresentable and its real
/// WKScriptMessageHandler. No replacement coordinator, delegate, bridge, URL or
/// account is injected. The full-route test uses real buttons and timers;
/// boundary tests send synthetic local payloads. These do not prove account
/// authentication, the protected outer App screen, or physical-device touches.
@MainActor
final class GameResultBridgeTests: XCTestCase {
    func testNatural108QuestionEndingEmitsExactlyOneProductionBridgeCallback() async throws {
        let host = try await readyHost()
        defer { host.close() }
        try await host.waitForScript("Foreground notice countdown", timeout: 10, """
        !document.hidden && document.visibilityState === 'visible' && !lifecyclePaused() &&
        document.getElementById('btn-accept')?.disabled === false
        """)
        let accepted: Bool = try await host.json("""
        (() => {
          const button = document.getElementById('btn-accept');
          if (!button || button.disabled || document.hidden || lifecyclePaused()) return false;
          button.click();
          return disclaimerAccepted && !document.getElementById('disclaimer') &&
            !document.getElementById('screen-intro').inert;
        })()
        """)
        XCTAssertTrue(accepted)
        guard accepted else { throw GameBridgeTestError.failed("Real entertainment notice was not accepted") }
        let started: Bool = try await host.json("""
        (() => {
          const origin = document.querySelector('.origin-item[data-id="peasant"]');
          const start = document.getElementById('btn-start');
          if (!origin || !start || start.disabled || document.hidden || lifecyclePaused()) return false;
          origin.click();
          start.click();
          return state.origin === 'peasant' && state.currentIdx === 0 &&
            activeScreen === 'game' && gameStarted && choiceTrace.length === 0;
        })()
        """)
        XCTAssertTrue(started)
        guard started else { throw GameBridgeTestError.failed("Real origin/start buttons did not begin a run") }
        let expectedChoices = (0..<108).map { $0 == 2 ? 1 : 0 }
        let startedAt = ContinuousClock.now
        for (index, choice) in expectedChoices.enumerated() {
            XCTAssertTrue(host.probe.received.isEmpty, "No result may leave JS before a real ending")
            let clicked: Bool = try await host.json("""
            (() => {
              if (document.hidden || lifecyclePaused() || state.dead || choiceLocked ||
                  state.currentIdx !== \(index) || state.totalAnswered !== \(index) ||
                  choiceTrace.length !== \(index)) return false;
              const button = document.querySelectorAll('#options button')[\(choice)];
              if (!button || button.disabled) return false;
              button.click();
              return true;
            })()
            """)
            XCTAssertTrue(clicked, "Real choice button was not ready at question \(index + 1)")
            guard clicked else { throw GameBridgeTestError.failed("Real choice was unavailable") }
            if index < 107 {
                try await host.waitForScript("Real next-question timer", timeout: 5, """
                !document.hidden && !lifecyclePaused() && !state.dead && !choiceLocked &&
                state.currentIdx === \(index + 1) && state.totalAnswered === \(index + 1) &&
                document.querySelectorAll('#options button:not(:disabled)').length === 4
                """)
            }
        }
        try await host.waitForScript("Real settlement and ending timers", timeout: 6,
                                    "!document.hidden && !lifecyclePaused() && state.dead && activeScreen === 'ending'")
        try await host.waitFor("Natural showEnding bridge delivery") { host.probe.received.count == 1 }
        XCTAssertGreaterThanOrEqual(startedAt.duration(to: .now), .seconds(38),
                                   "Do not replace or bypass the production 350/800/600 ms timers")
        let ending: GameNaturalEndingSnapshot = try await host.json("""
        ({ origin: state.origin, choices: choiceTrace.slice(), endingID: state.ending?.id,
           score: state.score, totalAnswered: state.totalAnswered, activeScreen })
        """)
        XCTAssertEqual(ending.origin, "peasant")
        XCTAssertEqual(ending.choices, expectedChoices)
        XCTAssertEqual(ending.endingID, "top_human")
        XCTAssertEqual(ending.score, 12_966)
        XCTAssertEqual(ending.totalAnswered, 108)
        XCTAssertEqual(ending.activeScreen, "ending")
        XCTAssertEqual(host.probe.received, [try GameRunPayload(origin: "peasant", choices: expectedChoices)])
        try await Task.sleep(for: .milliseconds(750))
        XCTAssertEqual(host.probe.received.count, 1, "The real ending must not emit a delayed duplicate")
        let restarted: Bool = try await host.json("""
        (() => {
          document.getElementById('btn-play-again').click();
          return activeScreen === 'intro' && !state.dead && choiceTrace.length === 0;
        })()
        """)
        XCTAssertTrue(restarted)
        XCTAssertEqual(host.probe.received.count, 1, "Restart itself does not prepare another result")
    }

    func testReadyProductionFileBridgeDeliversValidPayloadsForAllSixOrigins() async throws {
        let host = try await readyHost()
        defer { host.close() }
        let webView = try XCTUnwrap(host.webView)
        let expectedIndex = Bundle.main.bundleURL.appendingPathComponent("GameAssets/index.html")
            .resolvingSymlinksInPath().standardizedFileURL
        XCTAssertEqual(webView.url?.resolvingSymlinksInPath().standardizedFileURL, expectedIndex)
        XCTAssertFalse(webView.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(webView.isInspectable)
        for origin in GameRules.origins.sorted() {
            let choices = origin == "soldier" ? Array(repeating: 3, count: 108) : [0, 1, 2, 3]
            let expected = try GameRunPayload(origin: origin, choices: choices)
            let countBefore = host.probe.received.count
            try await host.post(["origin": origin, "choices": choices])
            try await host.waitFor("Actual production bridge callback") {
                host.probe.received.count > countBefore
            }
            XCTAssertEqual(host.probe.received.count, countBefore + 1)
            XCTAssertEqual(host.probe.received.last, expected)
        }
        XCTAssertEqual(host.probe.received.count, 6)
    }

    func testProductionBridgeRejectsAdditionalScoreIdentityConsentAndVersionFields() async throws {
        let host = try await readyHost()
        defer { host.close() }
        for key in ["score", "userID", "displayName", "consent", "rulesVersion"] {
            try await host.post(["origin": "peasant", "choices": [0], key: 1])
        }
        // A valid message after the rejected batch proves the callback is live;
        // an implementation rejecting every message cannot make this test pass.
        let sentinel = try GameRunPayload(origin: "teacher", choices: [2, 3])
        try await host.post(["origin": sentinel.origin, "choices": sentinel.choices])
        try await host.waitFor("Valid positive control after extra-field messages") {
            host.probe.received.contains(sentinel)
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(host.probe.received, [sentinel])
    }

    func testProductionBridgeRejectsBooleansFractionsOutOfRangeAndOversizedPayloads() async throws {
        let host = try await readyHost()
        defer { host.close() }
        let invalidPayloads: [[String: Any]] = [
            ["origin": "peasant", "choices": [true]],
            ["origin": "peasant", "choices": [false]],
            ["origin": "peasant", "choices": [1.5]],
            ["origin": "peasant", "choices": ["1"]],
            ["origin": "peasant", "choices": [-1]],
            ["origin": "peasant", "choices": [4]],
            ["origin": "peasant", "choices": []],
            ["origin": "peasant", "choices": Array(repeating: 0, count: 109)],
            ["origin": "unknown", "choices": [0]],
            ["origin": true, "choices": [0]],
            ["origin": "peasant"],
            ["origin": String(repeating: "x", count: 2_049), "choices": [0]],
        ]
        for payload in invalidPayloads { try await host.post(payload) }
        let sentinel = try GameRunPayload(origin: "worker", choices: [1, 0])
        try await host.post(["origin": sentinel.origin, "choices": sentinel.choices])
        try await host.waitFor("Valid positive control after malformed messages") {
            host.probe.received.contains(sentinel)
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(host.probe.received, [sentinel])
    }

    func testProductionBridgeRejectsSubframeMessagesWithoutRelaxingOfflinePolicy() async throws {
        let host = try await readyHost()
        defer { host.close() }
        let webView = try XCTUnwrap(host.webView)
        // Observation only: prove a message really came from the child frame.
        // The production handler, CSP, navigation delegate and file sandbox stay intact.
        let observer = GameBoundaryFrameObserver()
        webView.configuration.userContentController.add(observer, name: "gameBoundaryProbe")
        defer { webView.configuration.userContentController.removeScriptMessageHandler(forName: "gameBoundaryProbe") }
        let exercised: Bool = try await host.json("""
        (() => {
          const frame = document.createElement('iframe');
          frame.id = 'synthetic-boundary-frame';
          // No src/srcdoc/script, navigation, external URL or policy change.
          document.body.appendChild(frame);
          const handlers = frame.contentWindow?.webkit?.messageHandlers;
          if (!handlers?.gameBoundaryProbe || !handlers?.gameLeaderboard) {
            frame.remove();
            return false;
          }
          handlers.gameBoundaryProbe.postMessage({});
          handlers.gameLeaderboard.postMessage({ origin: 'business', choices: [3, 2] });
          return true;
        })()
        """)
        guard exercised else {
            throw XCTSkip("The unchanged offline CSP/WebKit host does not expose a child-frame bridge; do not weaken it for a test")
        }
        try await host.waitFor("Observed actual child-frame message") { !observer.mainFrames.isEmpty }
        XCTAssertEqual(observer.mainFrames, [false], "A parent-frame call cannot count as a subframe rejection test")
        let sentinel = try GameRunPayload(origin: "teacher", choices: [0, 1])
        try await host.post(["origin": sentinel.origin, "choices": sentinel.choices])
        try await host.waitFor("Main-frame positive control after child message") {
            host.probe.received.contains(sentinel)
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(host.probe.received, [sentinel])
    }

    func testInvalidatedProductionCoordinatorRejectsLateMessageWhileHandlerStillExists() async throws {
        let host = try await readyHost()
        defer { host.close() }
        let webView = try XCTUnwrap(host.webView)
        let coordinator = try XCTUnwrap(webView.navigationDelegate as? EmbeddedGameWebView.Coordinator)
        let sentinel = try GameRunPayload(origin: "worker", choices: [0, 1])
        try await host.post(["origin": sentinel.origin, "choices": sentinel.choices])
        try await host.waitFor("Live callback before production invalidation") {
            host.probe.received == [sentinel]
        }
        // This is the real method dismantleUIView calls. Keep its real script
        // handler registered temporarily to exercise a queued late-message race,
        // not merely an absent-JS-handler case. defer then tears down normally.
        coordinator.invalidate()
        try await host.post(["origin": "soldier", "choices": [3, 2]])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(host.probe.received, [sentinel])
    }

    private func readyHost() async throws -> GameResultBridgeHost {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Game bridge integration uses an isolated Simulator host, never an installed real-account App")
        #else
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let host = try GameResultBridgeHost()
        do {
            try await host.waitUntilReady()
            return host
        } catch {
            host.close()
            throw error
        }
        #endif
    }
}

private struct GameNaturalEndingSnapshot: Decodable {
    let origin: String
    let choices: [Int]
    let endingID: String?
    let score: Int
    let totalAnswered: Int
    let activeScreen: String
}

@MainActor
private final class GameBoundaryFrameObserver: NSObject, WKScriptMessageHandler {
    private(set) var mainFrames: [Bool] = []
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        mainFrames.append(message.frameInfo.isMainFrame)
    }
}

@MainActor
private final class GameBridgeProbe: ObservableObject {
    @Published var loadState: EmbeddedGameLoadState = .loading
    private(set) var received: [GameRunPayload] = []
    func receive(_ payload: GameRunPayload) { received.append(payload) }
}

private struct GameBridgeTestView: View {
    @ObservedObject var probe: GameBridgeProbe
    var body: some View {
        EmbeddedGameWebView(loadState: $probe.loadState, onRunCompleted: probe.receive)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum GameBridgeTestError: Error {
    case failed(String)
}

@MainActor
private final class GameResultBridgeHost {
    let probe = GameBridgeProbe()
    private let window: UIWindow
    var webView: WKWebView? { findWebView(in: window) }

    init() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }),
                                  "A foreground Simulator scene is required; no system prompt is dismissed by this test")
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let controller = UIHostingController(rootView: GameBridgeTestView(probe: probe))
        window.rootViewController = controller
        // Show only this synthetic game host without taking key focus or
        // modifying a real App window, session, capture flag or permission.
        window.isHidden = false
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }

    func waitUntilReady() async throws {
        try await waitFor("Production host ready and exposed", timeout: 25) {
            if case .failed(let message) = self.probe.loadState { throw GameBridgeTestError.failed(message) }
            guard self.probe.loadState == .ready, let webView = self.webView else { return false }
            return webView.window != nil && webView.isUserInteractionEnabled
                && !webView.accessibilityElementsHidden
        }
        let webView = try XCTUnwrap(webView)
        let value: Any? = try await evaluate("""
        document.readyState === 'complete' && location.protocol === 'file:' &&
        window === window.top && !document.hidden &&
        typeof window.webkit?.messageHandlers?.gameLeaderboard?.postMessage === 'function'
        """, in: webView)
        guard value as? Bool == true else {
            throw GameBridgeTestError.failed("Production document or bridge not ready")
        }
    }

    func post(_ payload: [String: Any]) async throws {
        let webView = try XCTUnwrap(webView)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let accepted = try await evaluate("""
        (() => {
          window.webkit.messageHandlers.gameLeaderboard.postMessage(\(json));
          return true;
        })()
        """, in: webView)
        XCTAssertEqual(accepted as? Bool, true, "The actual WK script handler must be callable")
    }

    func json<T: Decodable>(_ expression: String) async throws -> T {
        let webView = try XCTUnwrap(webView)
        let value = try await evaluate("JSON.stringify(\(expression))", in: webView)
        let text = try XCTUnwrap(value as? String, "Synthetic game expression did not return JSON")
        return try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    func waitForScript(_ label: String, timeout: TimeInterval = 5, _ expression: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            let ready: Bool = try await json(expression)
            if ready { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw GameBridgeTestError.failed("Timed out: \(label)")
    }

    func waitFor(_ label: String, timeout: TimeInterval = 5,
                 condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw GameBridgeTestError.failed("Timed out: \(label)")
    }

    func close() {
        webView?.stopLoading()
        window.isHidden = true
        // Removing the SwiftUI host invokes production dismantleUIView, which
        // unregisters its bridge and invalidates the real coordinator.
        window.rootViewController = nil
    }

    private func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }

    private func findWebView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for child in view.subviews {
            if let webView = findWebView(in: child) { return webView }
        }
        return nil
    }
}
