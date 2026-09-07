#!/usr/bin/env python3
"""Account preparation lifecycle checks with no real users or credentials."""
import copy
import importlib.util
import json
from pathlib import Path
import secrets
import unittest
from unittest.mock import patch
import uuid

spec = importlib.util.spec_from_file_location('review_accounts', Path(__file__).resolve().parents[1]
                                              / 'operations/prepare-review-accounts.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class ReviewAccountsTests(unittest.TestCase):
    def exercise(self, failed_path=None, cleanup_fails=False):
        saved = []
        requests = []
        minted = []
        roles = {}
        identities = {}
        owner = {'userID': 1, 'password': secrets.token_urlsafe(24), 'uuid': '00000000-0000-4000-8000-000000000001'}

        def evaluate(code):
            minted.append(code)
            if 'create_new_application_password' in code:
                return json.dumps(owner)
            if cleanup_fails:
                raise RuntimeError('synthetic cleanup failure')
            return 'true'

        def request(path, method='GET', body=None, auth=None, install=None):
            requests.append((path, method, body, auth, install))
            if path == failed_path:
                return 503, {}
            if path == 'fan/register':
                code = 'HS-ABCD-234' + str(len(roles) + 5)
                roles[code] = False
                identifier = str(uuid.uuid4())
                identities[identifier] = code
                profile = {'userID': identifier, 'identityCode': code, 'status': 'pending', 'administratorBound': False,
                           'displayName': body['displayName'], 'douyinID': body['douyinID']}
                return 201, {'profile': profile, 'token': secrets.token_urlsafe(24)}
            if path.endswith('/administrator'):
                roles[identities[path.split('/')[-2]]] = True
                return 200, {'user': {'administratorBound': True}}
            if path.startswith('app-admin/fans/'):
                return 200, {'user': {'administratorBound': False, 'administratorRevision': 0}}
            if path == 'fan/logout':
                return 200, {'ok': True}
            if path == 'fan/login':
                return 200, {'profile': {'administratorBound': roles[body['identityCode']]},
                             'token': body['identityCode']}
            if path == 'app-content':
                return 200, {'portfolios': [{}, {}]}
            if path == 'app-admin/session':
                if roles[auth.removeprefix('Bearer ')]:
                    return 200, {'canManageFanAdministrators': True}
                return 403, {}
            raise AssertionError('unexpected route')

        with patch.object(m.b, 'write_new'), patch.object(m, 'save', side_effect=lambda record: saved.append(copy.deepcopy(record))), \
                patch.object(m.a, 'wp_eval', side_effect=evaluate), patch.object(m.a, 'request', side_effect=request), \
                patch.object(m.a, 'catalog_snapshot'), patch.object(m, 'user_count', return_value=3), patch('builtins.print'):
            try:
                m.prepare(1)
                succeeded = True
            except RuntimeError:
                succeeded = False
        return succeeded, saved, requests, minted

    def test_two_normal_logins_with_different_roles(self):
        succeeded, saved, requests, minted = self.exercise()
        self.assertTrue(succeeded)
        self.assertTrue(saved[-1]['accountsPrepared'])
        self.assertFalse(saved[-1]['deliveredToApple'])
        self.assertNotIn('temporaryManagementCredentialUUID', saved[-1])
        self.assertEqual([a['displayName'] for a in saved[-1]['accounts']], list(m.LABELS))
        self.assertEqual([a['administrator'] for a in saved[-1]['accounts']], [False, True])
        self.assertTrue(all('bootstrapSession' not in a for a in saved[-1]['accounts']))
        self.assertEqual(sum(path == 'fan/login' for path, *_ in requests), 2)
        self.assertEqual(sum(path.endswith('/administrator') for path, *_ in requests), 1)
        self.assertEqual(sum(path == 'fan/logout' for path, *_ in requests), 4)
        self.assertIn('delete_application_password', minted[-1])

    def test_failed_registration_retains_incomplete_record_and_revokes_management_credential(self):
        succeeded, saved, _, minted = self.exercise(failed_path='fan/register')
        self.assertFalse(succeeded)
        self.assertTrue(all(not r['accountsPrepared'] for r in saved))
        self.assertIn('delete_application_password', minted[-1])

    def test_failed_temporary_credential_cleanup_never_marks_prepared(self):
        succeeded, saved, _, _ = self.exercise(cleanup_fails=True)
        self.assertFalse(succeeded)
        self.assertTrue(all(not r['accountsPrepared'] for r in saved))
        self.assertIn('temporaryManagementCredentialUUID', saved[-1])

    def test_registration_identity_and_initial_role_must_match(self):
        account = {'displayName': m.LABELS[0], 'douyinID': 'review.synthetic.' + uuid.uuid4().hex[:16]}
        profile = {**account, 'userID': str(uuid.uuid4()), 'identityCode': 'HS-ABCD-2345',
                   'status': 'pending', 'administratorBound': False}
        m.validate_registration(profile, account)
        for changes in ({'displayName': 'unrelated'}, {'douyinID': 'unrelated'}, {'status': 'active'},
                        {'administratorBound': True}, {'identityCode': 'Test1'}, {'userID': '../unrelated'}):
            with self.assertRaises((RuntimeError, ValueError)):
                m.validate_registration({**profile, **changes}, account)


if __name__ == '__main__':
    unittest.main()
