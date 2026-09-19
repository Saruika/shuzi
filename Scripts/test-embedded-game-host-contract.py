#!/usr/bin/env python3
"""Static release-integration guardrails, not a substitute for native UI tests.

Only production source and the Xcode project are inspected. Original upstream
fixtures are deliberately excluded from these offline-host checks.
"""

import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
ABOUT = (ROOT / "Yishu/Views/AboutView.swift").read_text(encoding="utf-8")
HOST = (ROOT / "Yishu/Views/EmbeddedGameView.swift").read_text(encoding="utf-8")
PROJECT = (ROOT / "Yishu.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
ASSETS = ROOT / "Yishu/Resources/GameAssets"
HTML = (ASSETS / "index.html").read_text(encoding="utf-8")
PRODUCTION_JS = "\n".join(file.read_text(encoding="utf-8") for file in sorted((ASSETS / "js").glob("*.js")))


def balanced_body(source, marker):
    """Return a marked brace body, ignoring ordinary strings and comments.

    Used on declaration/closure bodies without Swift multiline/raw strings.
    The host's JSON content rule is inspected separately with json.loads.
    """
    start = source.index(marker)
    opening = source.index("{", start + len(marker))
    tokens = re.finditer(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|[{}]', source[opening:])
    depth = 0
    for token in tokens:
        if token.group() == "{":
            depth += 1
        elif token.group() == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1:opening + token.start()]
    raise AssertionError("Unbalanced or absent body: " + marker)


def preprocessor_context(source, offset):
    stack = []
    for line in source[:offset].splitlines():
        stripped = line.strip()
        if stripped.startswith("#if "):
            stack.append(stripped[4:])
        elif stripped.startswith("#elseif "):
            if not stack:
                raise AssertionError("Unmatched #elseif")
            stack[-1] = stripped[8:]
        elif stripped == "#else":
            if not stack:
                raise AssertionError("Unmatched #else")
            stack[-1] = "alternative to " + stack[-1]
        elif stripped == "#endif":
            if not stack:
                raise AssertionError("Unmatched #endif")
            stack.pop()
    return stack


def pbx_object(identifier):
    marker = re.search(r"\b" + re.escape(identifier) + r"\s*(?:/\*.*?\*/\s*)?=\s*", PROJECT)
    if not marker:
        raise AssertionError("Missing project object " + identifier)
    return balanced_body(PROJECT, marker.group())


def pbx_section(name):
    return PROJECT.split("/* Begin " + name + " section */", 1)[1].split("/* End " + name + " section */", 1)[0]


def declared_ids(section):
    return re.findall(r"(?m)^\s*([A-Fa-f0-9]{24})\s*(?:/\*.*?\*/\s*)?=", section)


def application_phases():
    targets = [pbx_object(item) for item in declared_ids(pbx_section("PBXNativeTarget"))]
    applications = [item for item in targets if 'productType = "com.apple.product-type.application"' in item]
    if len(applications) != 1:
        raise AssertionError("Expected one application target")
    phases = re.search(r"buildPhases\s*=\s*\(([\s\S]*?)\);", applications[0]).group(1)
    return [pbx_object(identifier) for identifier in re.findall(r"\b[A-Fa-f0-9]{24}\b", phases)]


def build_reference(label):
    pattern = (r"([A-Fa-f0-9]{24})\s*/\*\s*" + re.escape(label)
               + r"\s*\*/\s*=\s*\{\s*isa\s*=\s*PBXBuildFile;\s*fileRef\s*=\s*([A-Fa-f0-9]{24})")
    match = re.search(pattern, pbx_section("PBXBuildFile"))
    if not match:
        raise AssertionError("Missing build reference " + label)
    return match.group(1), match.group(2)


class EmbeddedGameHostContract(unittest.TestCase):
    def test_completed_results_publish_automatically_with_upfront_disclosure(self):
        self.assertIn('await leaderboard.complete(payload, using: account)', HOST)
        self.assertIn('guard account.gameLeaderboardContext == expected', HOST)
        self.assertIn('开始体验即参与 App 内排行榜', HTML)
        self.assertIn('不再单独询问是否上榜', HTML)
        self.assertIn('同意并开始体验', HTML)
        self.assertNotIn('未选择上榜不会上传本局', HTML + PRODUCTION_JS)
        self.assertNotIn('上榜为自愿操作', HTML)
        board = (ROOT / 'Yishu/Views/GameLeaderboardView.swift').read_text()
        self.assertNotIn('confirmsSubmission', board)
        self.assertIn('await store.flushCompletedRuns(using: account)', board)
        self.assertIn('await store.remove(using: account)', board)

    def test_game_regressions_are_in_the_native_unit_test_compile_phase(self):
        # A file on disk/in a project group is not evidence that XCTest runs it.
        targets = [pbx_object(item) for item in declared_ids(pbx_section("PBXNativeTarget"))]
        unit_targets = [item for item in targets if 'productType = "com.apple.product-type.bundle.unit-test"' in item]
        self.assertEqual(len(unit_targets), 1)
        phase_ids = re.search(r"buildPhases\s*=\s*\(([\s\S]*?)\);", unit_targets[0]).group(1)
        phases = [pbx_object(item) for item in re.findall(r"\b[A-Fa-f0-9]{24}\b", phase_ids)]
        sources = [item for item in phases if "isa = PBXSourcesBuildPhase;" in item]
        self.assertEqual(len(sources), 1)
        for name in ("EmbeddedGameTests.swift", "GameLeaderboardTests.swift", "GameResultBridgeTests.swift"):
            build_id, file_id = build_reference(name + " in Sources")
            self.assertIn(build_id, sources[0], name)
            self.assertIn("path = " + name + ";", pbx_object(file_id))

    def test_about_entry_and_presentation_are_not_debug_only(self):
        markers = [
            "@State private var presentsEmbeddedGame",
            ".fullScreenCover(isPresented: $presentsEmbeddedGame)",
            "            embeddedGameAccess",
            "private var embeddedGameAccess:",
        ]
        for marker in markers:
            with self.subTest(marker=marker):
                self.assertIn(marker, ABOUT)
                conditions = preprocessor_context(ABOUT, ABOUT.index(marker))
                self.assertFalse(any(re.search(r"\bDEBUG\b", condition) for condition in conditions), conditions)
        entry = balanced_body(ABOUT, "private var embeddedGameAccess: some View")
        self.assertRegex(entry, r"Button\s*\{\s*presentsEmbeddedGame\s*=\s*true\s*\}")
        self.assertIn('.accessibilityIdentifier("about-embedded-game")', entry)
        self.assertNotRegex(entry, r"#if|_isDebugAssertConfiguration|ProcessInfo\.processInfo\.arguments")

    def test_full_screen_game_remains_inside_capture_protection_and_close_only_dismisses(self):
        presentation = balanced_body(ABOUT, ".fullScreenCover(isPresented: $presentsEmbeddedGame)")
        self.assertRegex(presentation, r"^\s*SecureCaptureSurface\(")
        self.assertIn("owner: .fullScreenPresentation", presentation)
        self.assertRegex(presentation, r"onExit:\s*\{\s*presentsEmbeddedGame\s*=\s*false\s*\}")
        self.assertRegex(presentation, r"EmbeddedGameView\(account:\s*fanAccount,\s*onClose:\s*\{\s*presentsEmbeddedGame\s*=\s*false\s*\}\)")
        self.assertNotRegex(presentation, r"logout|signOut|delete|remove|reset|admin|\.environmentObject")
        self.assertIn('Button("关闭游戏", role: .destructive) { onClose() }', HOST)

    def test_host_is_release_code_with_ephemeral_storage_and_no_identity_bridge(self):
        self.assertIn("struct EmbeddedGameView: View", HOST)
        self.assertNotRegex(HOST, r"(?m)^\s*#(?:if|elseif)\s+.*\bDEBUG\b")
        self.assertIn("configuration.websiteDataStore = .nonPersistent()", HOST)
        self.assertIn("configuration.preferences.javaScriptCanOpenWindowsAutomatically = false", HOST)
        self.assertIn("webView.isInspectable = false", HOST)
        self.assertNotRegex(HOST, r"addUserScript|WKUserScript|evaluateJavaScript|callAsyncJavaScript")
        self.assertNotRegex(HOST, r"AdminSessionStore|Keychain|accessToken|sessionToken|deviceToken|Authorization|URLSession|UserDefaults")
        self.assertIn('name: "gameLeaderboard"', HOST)
        self.assertIn('removeScriptMessageHandler(forName: "gameLeaderboard")', HOST)
        receive = balanced_body(HOST, 'func receive(_ message: WKScriptMessage)')
        for guard in ['message.frameInfo.isMainFrame', 'message.webView === hostedWebView',
                      'url.isFileURL', 'indexURL', 'data.count <= 2048',
                      'Set(body.keys) == Set(["origin", "choices"])', 'GameRunPayload.self']:
            self.assertIn(guard, receive)
        self.assertNotRegex(receive, r'URLSession|submitGameScore|submit\(run:')
        self.assertIn('weak var coordinator:', HOST)

    def test_file_read_scope_is_the_resolved_bundled_asset_directory(self):
        self.assertIn('bundle.appendingPathComponent("GameAssets", isDirectory: true)', HOST)
        self.assertIn('assets.appendingPathComponent("index.html")', HOST)
        self.assertGreaterEqual(HOST.count(".resolvingSymlinksInPath().standardizedFileURL"), 4)
        self.assertIn('assets.path.hasPrefix(bundle.path + "/")', HOST)
        self.assertIn('index.path.hasPrefix(assets.path + "/")', HOST)
        self.assertIn("webView.loadFileURL(index, allowingReadAccessTo: assets)", HOST)
        self.assertNotRegex(HOST, r"allowingReadAccessTo:\s*(?:bundle|Bundle|URL\()")
        permits = balanced_body(HOST, "private func permits(_ url: URL?) -> Bool")
        self.assertIn("url.isFileURL", permits)
        self.assertIn('resolved.path.hasPrefix(assetsDirectory.path + "/")', permits)

    def test_content_blocker_allows_only_local_file_resources(self):
        encoded = re.search(r'let rules\s*=\s*#"(.*?)"#', HOST).group(1)
        rules = json.loads(encoded)
        self.assertEqual(rules, [
            {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
            {"trigger": {"url-filter": "^file://"}, "action": {"type": "ignore-previous-rules"}},
        ])
        self.assertIn("webView.configuration.userContentController.add(list)", HOST)
        self.assertRegex(HOST, r"guard let list else\s*\{\s*self\.fail\(")

    def test_external_navigation_downloads_new_windows_and_save_menus_are_refused(self):
        action = balanced_body(HOST, "decidePolicyFor action: WKNavigationAction,")
        self.assertIn("action.targetFrame?.isMainFrame == true", action)
        self.assertIn("!action.shouldPerformDownload", action)
        self.assertIn("permits(action.request.url)", action)
        self.assertRegex(action, r"else\s*\{\s*decisionHandler\(\.cancel\)\s*return")
        response = balanced_body(HOST, "decidePolicyFor response: WKNavigationResponse,")
        self.assertIn("permits(response.response.url)", response)
        self.assertIn("response.canShowMIMEType ? .allow : .cancel", response)
        new_window = balanced_body(HOST, "createWebViewWith configuration: WKWebViewConfiguration,")
        self.assertEqual(new_window.strip(), "nil")
        menu = balanced_body(HOST, "contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,")
        self.assertEqual(menu.strip(), "completionHandler(nil)")
        self.assertNotRegex(HOST, r"UIApplication\.shared\.open|SFSafariViewController|WKDownloadDelegate")

    def test_packaged_javascript_has_no_platform_identity_network_or_persistent_storage(self):
        self.assertIn("const LOCAL_PLAYER_NAME = '本局玩家';", PRODUCTION_JS)
        self.assertNotRegex(PRODUCTION_JS, r"ToySDK|TOYID|toyid|PosterMaker|accessToken|sessionToken|identityCode|douyinID")
        self.assertEqual(PRODUCTION_JS.count('messageHandlers'), 1)
        self.assertEqual(PRODUCTION_JS.count('.postMessage('), 1)
        self.assertIn('gameLeaderboard', PRODUCTION_JS)
        self.assertNotRegex(PRODUCTION_JS, r"\bfetch\s*\(|XMLHttpRequest|WebSocket|EventSource|sendBeacon|https?://")
        self.assertNotRegex(PRODUCTION_JS, r"localStorage|sessionStorage|indexedDB|document\.cookie|CacheStorage|\bcaches\.")
        self.assertNotRegex(PRODUCTION_JS, r"toDataURL|createObjectURL|\.download\s*=|window\.open|location\.(?:href|replace|assign)")
        self.assertNotRegex(HTML, r"toy-sdk|toy\.js|poster\.js|<iframe|<script(?![^>]*\bsrc=)[^>]*>")
        for declaration in ["default-src 'none'", "script-src 'self'", "connect-src 'none'", "frame-src 'none'"]:
            self.assertIn(declaration, HTML)

    def test_game_assets_are_in_the_application_resource_phase_as_a_folder(self):
        build_id, file_id = build_reference("GameAssets in Resources")
        resources = [phase for phase in application_phases() if "isa = PBXResourcesBuildPhase;" in phase]
        self.assertEqual(len(resources), 1)
        self.assertRegex(resources[0], r"\b" + build_id + r"\b")
        reference = pbx_object(file_id)
        self.assertIn("lastKnownFileType = folder;", reference)
        self.assertIn("path = GameAssets;", reference)
        groups = [pbx_object(identifier) for identifier in declared_ids(pbx_section("PBXGroup"))]
        self.assertTrue(any(file_id in group and "path = Yishu/Resources;" in group for group in groups))
        for filename in ["index.html", "css/style.css", "js/main.js", "js/events.js", "js/endings.js"]:
            self.assertTrue((ASSETS / filename).is_file(), filename)

    def test_game_host_is_in_application_sources_not_merely_a_project_group(self):
        build_id, file_id = build_reference("EmbeddedGameView.swift in Sources")
        sources = [phase for phase in application_phases() if "isa = PBXSourcesBuildPhase;" in phase]
        self.assertEqual(len(sources), 1)
        self.assertRegex(sources[0], r"\b" + build_id + r"\b")
        reference = pbx_object(file_id)
        self.assertIn("lastKnownFileType = sourcecode.swift;", reference)
        self.assertIn("path = EmbeddedGameView.swift;", reference)

    def test_raw_reference_fixtures_and_platform_adapters_are_not_shipped(self):
        # Only resolve application resource references; do not inspect the
        # original baseline's intentionally unmodified platform code.
        resources = next(phase for phase in application_phases() if "isa = PBXResourcesBuildPhase;" in phase)
        files = re.search(r"files\s*=\s*\(([\s\S]*?)\);", resources).group(1)
        for identifier in re.findall(r"\b[A-Fa-f0-9]{24}\b", files):
            build = pbx_object(identifier)
            reference_id = re.search(r"fileRef\s*=\s*([A-Fa-f0-9]{24})", build).group(1)
            reference = pbx_object(reference_id)
            self.assertNotRegex(reference, r"GameReference|YishuTests|original-source|toy\.js|poster\.js")
        paths = [file.relative_to(ASSETS).as_posix() for file in ASSETS.rglob("*") if file.is_file()]
        self.assertFalse(any(re.search(r"GameReference|original-source|(?:^|/)(?:toy|poster)\.js$", file) for file in paths))
        self.assertEqual(sorted(file for file in paths if file.endswith(".js")), ["js/endings.js", "js/events.js", "js/main.js"])
        for identifier in declared_ids(pbx_section("PBXShellScriptBuildPhase")) if "/* Begin PBXShellScriptBuildPhase section */" in PROJECT else []:
            self.assertNotIn("GameReference", pbx_object(identifier))


if __name__ == "__main__":
    unittest.main(verbosity=2)
