#!/usr/bin/env python3
"""Guard local privacy artifacts; does not claim ASC or website publication."""
import json
from pathlib import Path
import plistlib
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PrivacyAlignmentTests(unittest.TestCase):
    def test_manifest_matches_reviewed_disclosure(self):
        mapping = json.loads((ROOT / 'Server/app-store/privacy-disclosure.json').read_text())
        manifest = plistlib.loads((ROOT / 'Yishu/Resources/PrivacyInfo.xcprivacy').read_bytes())
        entries = manifest['NSPrivacyCollectedDataTypes']
        actual = {item['NSPrivacyCollectedDataType'].removeprefix('NSPrivacyCollectedDataType'): item
                  for item in entries}
        self.assertEqual(len(actual), len(entries), 'Duplicate declarations are ambiguous')
        self.assertEqual(set(actual), set(mapping['dataTypes']))
        self.assertFalse(manifest['NSPrivacyTracking'])
        self.assertEqual(manifest['NSPrivacyTrackingDomains'], [])
        for name, spec in mapping['dataTypes'].items():
            with self.subTest(name=name):
                self.assertEqual(actual[name]['NSPrivacyCollectedDataTypeLinked'], spec['linked'])
                self.assertFalse(actual[name]['NSPrivacyCollectedDataTypeTracking'])
                self.assertEqual(actual[name]['NSPrivacyCollectedDataTypePurposes'],
                                 ['NSPrivacyCollectedDataTypePurposeAppFunctionality'])

    def test_contact_and_support_explanations_exist_in_both_policies(self):
        for path in ['Yishu/Views/PrivacyPolicyView.swift', 'Server/app-privacy-policy.html']:
            source = (ROOT / path).read_text()
            for phrase in ['电话号码或微信', '客户支持', '与可识别的发件人关联', '不会自动复制表单',
                           '合作邮箱', '粗略位置', '消息箱']:
                with self.subTest(path=path, phrase=phrase):
                    self.assertIn(phrase, source)

    def test_privacy_mailbox_and_link_match_in_app_and_website(self):
        catalog = (ROOT / 'Yishu/Models/Portfolio.swift').read_text()
        app_policy = (ROOT / 'Yishu/Views/PrivacyPolicyView.swift').read_text()
        web_policy = (ROOT / 'Server/app-privacy-policy.html').read_text()
        address = 'support@shuzijun.com.cn'
        self.assertIn(f'static let privacyContactEmailAddress = "{address}"', catalog)
        self.assertIn(
            r'static let privacyEmailURL = AppURL.make("mailto:\(privacyContactEmailAddress)")',
            catalog,
        )
        self.assertIn(r'\(ContentCatalog.privacyContactEmailAddress)', app_policy)
        self.assertIn('Link(destination: ContentCatalog.privacyEmailURL)', app_policy)
        self.assertIn(f'<a href="mailto:{address}">{address}</a>', web_policy)
        for source in (catalog, app_policy, web_policy):
            self.assertNotIn('sariki@me.com', source.lower())

    def test_collaboration_keeps_its_separate_qq_mailbox(self):
        catalog = (ROOT / 'Yishu/Models/Portfolio.swift').read_text()
        web_policy = (ROOT / 'Server/app-privacy-policy.html').read_text()
        address = '369476120@qq.com'
        self.assertIn(f'static let collaborationEmailAddress = "{address}"', catalog)
        self.assertIn(f'static let emailURL = AppURL.make("mailto:{address}")', catalog)
        self.assertIn(f'<a href="mailto:{address}">{address}</a>', web_policy)

    def test_collaboration_uses_live_session_not_legacy_keychain(self):
        source = (ROOT / 'Yishu/Views/CollaborationInquiryView.swift').read_text()
        self.assertNotIn('SecItemCopyMatching', source)
        self.assertNotIn('CollaborationFanCredential', source)
        self.assertNotIn('private let apiRoot = AppURL.make', source)
        self.assertIn('account.authorizeCollaborationRequest', source)
        self.assertIn('.task(id: fanAccount.collaborationContext)', source)
        self.assertIn('http.url == endpoint', source)


if __name__ == '__main__':
    unittest.main()
