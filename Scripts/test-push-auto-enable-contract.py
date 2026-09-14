#!/usr/bin/env python3
"""Check auto-binding integration and deletion boundaries without live accounts."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PushAutoEnableContractTests(unittest.TestCase):
    def test_auto_enable_follows_eligibility_and_current_session_checks(self):
        source = (ROOT / 'Yishu/Services/PushNotificationService.swift').read_text()
        sync = source.split('private func synchronize(', 1)[1].split(
            'func requestAuthorizationAfterRationale', 1)[0]
        eligibility = sync.index('guard let eligibleUserID = account.pushEligibleUserID')
        current_session = sync.index('account.pushSessionGeneration == sessionGeneration')
        automatic = sync.index('PushNotificationPreferencePolicy.enableAfterSystemAuthorization(')
        binding = sync.index('beginDeviceRegistration(for: account)')
        self.assertLess(eligibility, current_session)
        self.assertLess(current_session, automatic)
        self.assertLess(automatic, binding)
        self.assertIn('account.serviceEnvironment == serviceEnvironment', sync)
        policy = source.split('static func enableAfterSystemAuthorization(', 1)[1].split(
            'static func remove(', 1)[0]
        self.assertIn('status == .authorized', policy)
        self.assertIn('!hasExplicitChoice', policy)

    def test_only_confirmed_deletion_clears_notification_preferences(self):
        source = (ROOT / 'Yishu/Services/FanAccountStore.swift').read_text()
        for start, end in [('func deleteAccount(', 'func deleteAppleAccount('),
                           ('func deleteAppleAccount(', 'func fetchApprovedContent(')]:
            with self.subTest(function=start):
                body = source.split(start, 1)[1].split(end, 1)[0]
                success, failure = body.split('} catch {', 1)
                self.assertLess(success.index('guard response.ok'),
                                success.index('confirmedDeletedAccountUserID = deletingUserID'))
                self.assertNotIn('confirmedDeletedAccountUserID =', failure)
        root = (ROOT / 'Yishu/Views/RootView.swift').read_text()
        hook = root.split('.onChange(of: fanAccount.confirmedDeletedAccountUserID', 1)[1].split(
            '.onChange(', 1)[0]
        self.assertIn('pushNotifications.removePreferenceForDeletedAccount(userID)', hook)


if __name__ == '__main__':
    unittest.main()
