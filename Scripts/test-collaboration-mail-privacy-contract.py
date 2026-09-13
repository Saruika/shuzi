#!/usr/bin/env python3
"""Keep mail failure from silently exporting form data to the clipboard."""
from pathlib import Path
import unittest


SOURCE = (Path(__file__).resolve().parents[1]
          / "Yishu/Views/CollaborationInquiryView.swift").read_text()


class CollaborationMailPrivacyTests(unittest.TestCase):
    def test_mail_failure_only_prompts_and_never_copies(self):
        send = SOURCE.split("private func sendEmail()", 1)[1].split("\n}\n", 1)[0]
        self.assertNotIn("UIPasteboard", send)
        self.assertNotIn("copyInquiry()", send)
        self.assertEqual(send.count("showMailFallback = true"), 2)
        self.assertIn("guard let url = components.url", send)
        self.assertIn("guard !accepted else { return }", send)

    def test_copy_remains_an_explicit_action(self):
        self.assertEqual(SOURCE.count("UIPasteboard.general.string = inquiryText"), 1)
        self.assertEqual(SOURCE.count("copyInquiry()"), 3)  # declaration and two buttons
        self.assertIn('Button("复制邀约内容") { copyInquiry() }', SOURCE)
        self.assertIn("邀约尚未发送，也未自动复制。", SOURCE)
        self.assertNotIn("邀约内容已经复制，可在任意", SOURCE)


if __name__ == "__main__":
    unittest.main()
