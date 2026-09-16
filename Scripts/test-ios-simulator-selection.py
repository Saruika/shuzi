#!/usr/bin/env python3
"""Offline regression tests for explicit/latest iOS compatibility coverage."""
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("simulator_selection", Path(__file__).with_name("select-ios-simulator.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def device(number, name, available=True):
    return {"udid": f"00000000-0000-0000-0000-{number:012d}", "name": name, "isAvailable": available}


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.payload = {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [device(1, "iPhone 17 Pro Max"), device(2, "iPad Pro 13-inch (M5)")],
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [device(3, "iPhone 18 Pro"), device(4, "iPhone 18 Pro Max"), device(5, "iPad Pro 13-inch (M5)")],
        }}

    def test_latest_selects_new_os_before_old_preferred_hardware(self):
        self.payload["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-27-0"].pop(1)
        self.assertEqual(MODULE.select_device(self.payload, "iPhone"), device(3, "")['udid'])

    def test_latest_prefers_pro_max_and_large_ipad(self):
        self.assertEqual(MODULE.select_device(self.payload, "iPhone"), device(4, "")['udid'])
        self.assertEqual(MODULE.select_device(self.payload, "iPad"), device(5, "")['udid'])

    def test_explicit_legacy_runtime_is_preserved(self):
        self.assertEqual(MODULE.select_device(self.payload, "iPhone", "26.5"), device(1, "")['udid'])

    def test_explicit_new_runtime_does_not_depend_on_listing_order(self):
        expected = MODULE.select_device(self.payload, "iPhone", "27.0")
        self.payload["devices"] = dict(reversed(list(self.payload["devices"].items())))
        self.assertEqual(MODULE.select_device(self.payload, "iPhone", "27.0"), expected)

    def test_absent_requested_runtime_never_falls_back(self):
        with self.assertRaises(ValueError):
            MODULE.select_device(self.payload, "iPhone", "28.0")

    def test_unavailable_new_runtime_is_not_used(self):
        for entry in self.payload["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-27-0"]:
            entry["isAvailable"] = False
        with self.assertRaises(ValueError):
            MODULE.select_device(self.payload, "iPhone", "27.0")

    def test_runtime_versions_sort_numerically(self):
        self.payload["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-9-3"] = [device(6, "iPhone Pro Max")]
        self.assertEqual(MODULE.select_device(self.payload, "iPhone"), device(4, "")['udid'])

    def test_unrelated_platform_invalid_identifier_and_family_are_rejected(self):
        payload = {"devices": {"com.apple.CoreSimulator.SimRuntime.tvOS-27-0": [device(7, "iPhone 18 Pro Max")]}}
        with self.assertRaises(ValueError):
            MODULE.select_device(payload, "iPhone")
        payload = {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-0": [{"name": "iPhone 18 Pro Max", "isAvailable": True, "udid": "bad"}]}}
        with self.assertRaises(ValueError):
            MODULE.select_device(payload, "iPhone")
        with self.assertRaises(ValueError):
            MODULE.select_device(self.payload, "Mac")

    def test_version_alias_and_invalid_version(self):
        self.assertEqual(MODULE.select_device(self.payload, "iPhone", "27"), MODULE.select_device(self.payload, "iPhone", "27.0.0"))
        for value in ("27x", "", "27.0.0.1", "-1", "27;true"):
            with self.assertRaises(ValueError):
                MODULE.select_device(self.payload, "iPhone", value)


if __name__ == "__main__":
    unittest.main()
