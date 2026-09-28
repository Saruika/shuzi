#!/usr/bin/env python3
"""Guard bounded chunk transport, lazy shared sessions and Debug-only launch routing."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def release_init(source):
    initializer = source.split("    init() {", 1)[1].split("    private var themedAccessContent", 1)[0]
    enabled = True
    result = []
    for line in initializer.splitlines():
        if line.strip() == "#if DEBUG":
            enabled = False
        elif line.strip() == "#else":
            enabled = True
        elif line.strip() == "#endif":
            enabled = True
        elif enabled:
            result.append(line)
    return "\n".join(result)


class NetworkAuditContractTests(unittest.TestCase):
    def test_release_initializer_never_reads_visual_launch_arguments(self):
        source = (ROOT / "Yishu/Views/RootView.swift").read_text()
        release = release_init(source)
        self.assertNotIn("ProcessInfo", release)
        self.assertNotIn("-visual-portfolio-title=", release)
        self.assertIn("visualPortfolioTitle = nil", release)
        self.assertIn("initialTab = .home", release)
        self.assertNotIn("initialTab = title", release)
        self.assertIn('-visual-portfolio-title=', source)  # Debug support is retained.

    def test_collaboration_default_uses_lazy_shared_stateless_session(self):
        source = (ROOT / "Yishu/Views/CollaborationInquiryView.swift").read_text()
        client = source.split("struct CollaborationSubmissionClient {", 1)[1]
        self.assertIn("private static let sharedSession = SecureURLSessionFactory.make(", client)
        self.assertIn("init(session: URLSession? = nil)", client)
        self.assertIn("let session = session ?? Self.sharedSession", client)
        self.assertEqual(client.count("SecureURLSessionFactory.make("), 1)

    def test_public_and_drama_loaders_do_not_iterate_bytes_or_use_unbounded_data(self):
        for path in ("PublicExperienceStore.swift", "DramaLinkHealth.swift"):
            with self.subTest(path=path):
                source = (ROOT / "Yishu/Services" / path).read_text()
                self.assertIn("BoundedResponseLoader.data(", source)
                self.assertNotIn("for try await byte", source)
                self.assertNotIn("session.data(for:", source)
                self.assertNotIn("session.bytes(", source)

    def test_existing_redirect_boundaries_are_retained(self):
        source = (ROOT / "Yishu/Services/SecureNetworkClient.swift").read_text()
        self.assertIn("RedirectValidator = { _, _ in false }", source)
        self.assertIn("data.count <= maximumBytes - body.count", source)
        self.assertIn("session?.invalidateAndCancel()", source)
        drama = (ROOT / "Yishu/Services/DramaLinkHealth.swift").read_text()
        self.assertIn("count <= 5 && request.url.map(DramaLinkPolicy.isHongguo) == true", drama)


if __name__ == "__main__":
    unittest.main(verbosity=2)
