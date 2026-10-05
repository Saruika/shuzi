#!/usr/bin/env python3
"""Guard local privacy artifacts; does not claim ASC or website publication."""
import json
from pathlib import Path
import plistlib
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PrivacyAlignmentTests(unittest.TestCase):
    def test_retired_game_keeps_history_and_real_deletion_routes_disclosed(self):
        for path in ['Yishu/Views/PrivacyPolicyView.swift', 'Server/app-privacy-policy.html']:
            source = (ROOT / path).read_text()
            for phrase in ['历史游戏数据', '当前版本不再提供小游戏或排行榜', '不会提交新的游戏成绩',
                           '小游戏与排行榜服务已停用', '不再接受或展示游戏成绩', '相关在线排行榜记录已清理',
                           '一条最高成绩摘要', '选项仅用于当次重演', '不接入第三方游戏平台账号',
                           '受限访问的回滚备份可能仍含历史记录', '不用于日常业务或恢复小游戏与排行榜服务',
                           '按既有保留期限处理', '隐私邮箱', '申请查阅或删除', '在 App 内发起删除账号与个人资料']:
                with self.subTest(path=path, phrase=phrase):
                    self.assertIn(phrase, source)
            self.assertNotIn('游戏与自动上榜', source)
            self.assertNotIn('你可在排行榜移除自己的记录', source)
            self.assertNotIn('旧版本仍可能按其原有流程提交', source)

    def test_partial_online_retirement_does_not_claim_full_disclosure_alignment(self):
        mapping = json.loads((ROOT / 'Server/app-store/privacy-disclosure.json').read_text())
        self.assertEqual(mapping['scope'], 'current-app-build-only')
        self.assertEqual(mapping['status'], 'local-candidate-not-confirmed-in-app-store-connect')
        self.assertEqual(mapping['legacyGameData']['status'], 'decommission-release-candidate')
        self.assertIn('须先核实', mapping['legacyGameData']['publicationPrerequisite'])
        self.assertIn('仅移除 Apple 在线披露的游戏内容一项', mapping['appStoreConnectReviewNote'])
        self.assertIn('网页回读 12 项', mapping['appStoreConnectReviewNote'])
        self.assertIn('其余线上用途与关联设置未改', mapping['appStoreConnectReviewNote'])
        self.assertIn('不宣称与线上问卷逐项完全一致', mapping['appStoreConnectReviewNote'])
        self.assertIn('本地待发布候选：须先完成游戏服务停用与在线排行榜记录清理',
                      (ROOT / 'Server/app-privacy-policy.html').read_text())
        listing = json.loads((ROOT / 'Server/app-store/zh-Hans.json').read_text())
        self.assertNotRegex(listing['description'], r'游戏|排行榜|自动上榜|宦海浮沉录')

    def test_manifest_matches_reviewed_disclosure(self):
        mapping = json.loads((ROOT / 'Server/app-store/privacy-disclosure.json').read_text())
        manifest = plistlib.loads((ROOT / 'Yishu/Resources/PrivacyInfo.xcprivacy').read_bytes())
        entries = manifest['NSPrivacyCollectedDataTypes']
        actual = {item['NSPrivacyCollectedDataType'].removeprefix('NSPrivacyCollectedDataType'): item
                  for item in entries}
        self.assertEqual(len(actual), len(entries), 'Duplicate declarations are ambiguous')
        self.assertEqual(set(actual), set(mapping['dataTypes']))
        self.assertNotIn('GameplayContent', actual)
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
                           '合作邮箱', '消息箱']:
                with self.subTest(path=path, phrase=phrase):
                    self.assertIn(phrase, source)

    def test_weather_retirement_is_version_scoped(self):
        web = (ROOT / 'Server/app-privacy-policy.html').read_text()
        self.assertIn('自 1.5（Build 4）起', web)
        self.assertIn('不请求定位权限', web)
        self.assertIn('此前版本仅在用户主动开启时', web)
        self.assertNotIn('提供用户主动请求的天气', web)
        listing = json.loads((ROOT / 'Server/app-store/zh-Hans.json').read_text())
        self.assertNotIn('天气', listing['description'])

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

    def test_both_policies_explain_automatic_notifications_and_account_opt_out(self):
        for path in ['Yishu/Views/PrivacyPolicyView.swift', 'Server/app-privacy-policy.html']:
            source = (ROOT / path).read_text()
            for phrase in ['系统已允许通知', '无需再手动打开 App 内开关',
                           '未登录或资料未完成时不会上传设备令牌', '账号哈希',
                           '服务器确认账号删除后清除该账号本机偏好', '不继承旧账号设备绑定或消息']:
                with self.subTest(path=path, phrase=phrase):
                    self.assertIn(phrase, source)

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
