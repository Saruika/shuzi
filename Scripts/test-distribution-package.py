#!/usr/bin/env python3
"""Synthetic package-metadata checks; never read a keychain or real profile."""
import contextlib
import copy
from datetime import datetime, timedelta, timezone
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("distribution_package", Path(__file__).with_name("check-distribution-package.py"))
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class DistributionPackageTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 9, 7, tzinfo=timezone.utc)
        self.info = {"CFBundleIdentifier": CHECKER.BUNDLE, "CFBundleShortVersionString": "1.4.0",
                     "CFBundleVersion": "4", "CFBundleSupportedPlatforms": ["iPhoneOS"],
                     "UIDeviceFamily": [1, 2], "MinimumOSVersion": "17.0"}
        self.rights = {"application-identifier": CHECKER.TEAM + "." + CHECKER.BUNDLE,
                       "com.apple.developer.team-identifier": CHECKER.TEAM, "get-task-allow": False,
                       "aps-environment": "production", "com.apple.developer.weatherkit": True,
                       "com.apple.developer.applesignin": ["Default"]}
        self.profile = {"TeamIdentifier": [CHECKER.TEAM], "ExpirationDate": self.now + timedelta(days=1),
                        "Entitlements": copy.deepcopy(self.rights)}
        self.privacy = {"NSPrivacyTracking": False, "NSPrivacyTrackingDomains": []}

    def check(self):
        CHECKER.check_metadata(self.info, self.rights, self.profile, self.privacy, "1.4.0", "4", self.now)

    def test_valid_distribution_metadata_and_naive_utc_expiry(self):
        self.check()
        self.profile["ExpirationDate"] = self.profile["ExpirationDate"].replace(tzinfo=None)
        self.check()

    def test_stale_build_and_other_project_rejected(self):
        for key, value in (("CFBundleVersion", "3"), ("CFBundleShortVersionString", "1.3.41"),
                           ("CFBundleIdentifier", "example.invalid.other")):
            with self.subTest(key=key), patch.dict(self.info, {key: value}), self.assertRaises(CHECKER.PackageCheckError):
                self.check()

    def test_simulator_missing_ipad_or_wrong_minimum_rejected(self):
        for key, value in (("CFBundleSupportedPlatforms", ["iPhoneSimulator"]), ("UIDeviceFamily", [1]),
                           ("MinimumOSVersion", "26.0")):
            with self.subTest(key=key), patch.dict(self.info, {key: value}), self.assertRaises(CHECKER.PackageCheckError):
                self.check()

    def test_effective_and_profile_permissions_are_both_required(self):
        changes = {"aps-environment": "development", "get-task-allow": True,
                   "com.apple.developer.weatherkit": False, "com.apple.developer.applesignin": [],
                   "application-identifier": CHECKER.TEAM + ".*", "com.apple.developer.team-identifier": "OTHER"}
        for rights in (self.rights, self.profile["Entitlements"]):
            for key, value in changes.items():
                with self.subTest(key=key), patch.dict(rights, {key: value}), self.assertRaises(CHECKER.PackageCheckError):
                    self.check()

    def test_missing_rights_are_not_false_or_enabled_by_default(self):
        for key in tuple(self.rights):
            saved = self.rights.pop(key)
            with self.subTest(key=key), self.assertRaises(CHECKER.PackageCheckError):
                self.check()
            self.rights[key] = saved

    def test_profile_expired_adhoc_enterprise_and_wrong_team_rejected(self):
        for key, value in (("ExpirationDate", self.now), ("ExpirationDate", "tomorrow"),
                           ("ProvisionedDevices", []), ("ProvisionsAllDevices", True),
                           ("TeamIdentifier", ["OTHER"]), ("Entitlements", [])):
            with self.subTest(key=key), patch.dict(self.profile, {key: value}), self.assertRaises(CHECKER.PackageCheckError):
                self.check()

    def test_tracking_and_arbitrary_http_not_silently_enabled(self):
        for key in ("NSAllowsArbitraryLoads", "NSAllowsArbitraryLoadsForMedia", "NSAllowsArbitraryLoadsInWebContent",
                    "NSAllowsLocalNetworking", "NSExceptionDomains"):
            with patch.dict(self.info, {"NSAppTransportSecurity": {key: True}}), self.assertRaises(CHECKER.PackageCheckError):
                self.check()
        for key, value in (("NSPrivacyTracking", True), ("NSPrivacyTrackingDomains", ["example.invalid"])):
            with patch.dict(self.privacy, {key: value}), self.assertRaises(CHECKER.PackageCheckError):
                self.check()

    def test_tool_failure_and_timeout_never_forward_private_output(self):
        reply = subprocess.CompletedProcess([], 1, b"SYNTHETIC_PROFILE_DATA", b"SYNTHETIC_CERTIFICATE_DATA")
        with patch.object(CHECKER.subprocess, "run", return_value=reply) as run:
            with self.assertRaisesRegex(CHECKER.PackageCheckError, "^apple_tool_failed$"):
                CHECKER.command(["/usr/bin/codesign", "--verify", "/synthetic.app"])
            self.assertFalse(run.call_args.kwargs.get("shell", False))
            self.assertEqual(run.call_args.kwargs["timeout"], 30)
        with patch.object(CHECKER, "check_package", side_effect=subprocess.TimeoutExpired("SYNTHETIC_PRIVATE", 30)):
            output = self.main_output()
            self.assertNotIn("SYNTHETIC_PRIVATE", output)

    def main_output(self):
        output = io.StringIO()
        with patch.object(sys, "argv", ["check", "--app", "/synthetic.app", "--version", "1.4.0", "--build", "4"]), contextlib.redirect_stdout(output):
            self.assertEqual(CHECKER.main(), 1)
        return output.getvalue()

    def test_cli_names_failed_check_without_claiming_submission_ready(self):
        with patch.object(CHECKER, "check_package", side_effect=CHECKER.PackageCheckError("build_number_mismatch")):
            self.assertEqual(json.loads(self.main_output()), {"packageCheck": "failed", "check": "build_number_mismatch"})

    def test_invalid_metadata_shape_is_rejected(self):
        with self.assertRaises(CHECKER.PackageCheckError):
            CHECKER.decode_plist(b'<?xml version="1.0"?><plist version="1.0"><array/></plist>')
        for payload in (b'SYNTHETIC_PRIVATE', b'<?xml version="1.0"?><plist><dict>SYNTHETIC_PRIVATE'):
            with self.assertRaisesRegex(CHECKER.PackageCheckError, "^invalid_metadata_encoding$"):
                CHECKER.decode_plist(payload)


if __name__ == "__main__":
    unittest.main()
