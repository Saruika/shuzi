#!/usr/bin/env python3
"""Validate summaries and CI continuation without spending Actions minutes."""
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ci_test_summary", ROOT / "Scripts/ci-test-summary.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def payload(failed=False):
    return {
        "result": "Failed" if failed else "Passed", "totalTestCount": 1,
        "passedTests": 0 if failed else 1, "failedTests": 1 if failed else 0, "skippedTests": 0,
        "devicesAndConfigurations": [{"passedTests": 0 if failed else 4,
                                      "failedTests": 4 if failed else 0, "skippedTests": 0}],
        "testFailures": [{"testIdentifierString": "GalleryTests/testClose",
                          "failureText": "PRIVATE_RUNTIME_VALUE",
                          "testName": "PRIVATE_RUNTIME_VALUE"}] if failed else [],
    }


class TestSummary(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="yishu-summary-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def bundle(self, name="Yishu-iPad-fixture.xcresult", finalized=True):
        result = self.root / name
        result.mkdir()
        if finalized:
            (result / "Info.plist").write_text("fixture", encoding="utf-8")
        return result

    def render(self, data, environment=None):
        response = subprocess.CompletedProcess([], 0, json.dumps(data), "")
        with patch.object(MODULE.subprocess, "run", return_value=response) as run:
            result = MODULE.render(self.root, environment or {})
        return result, run

    def test_counts_distinguish_cases_and_parameterized_executions(self):
        self.bundle()
        (report, failed), run = self.render(payload())
        self.assertFalse(failed)
        self.assertIn("总用例 1，通过 1", report)
        self.assertIn("设备/参数化执行：通过 4", report)
        self.assertEqual(run.call_args.kwargs["timeout"], 20)
        self.assertTrue(run.call_args.kwargs["check"])
        self.assertNotIn("shell", run.call_args.kwargs)

    def test_failed_summary_cannot_become_success_or_expose_assertions(self):
        self.bundle()
        data = payload(True)
        data["testFailures"].append({"testIdentifierString": "bad<script>|injection"})
        (report, failed), _ = self.render(data)
        self.assertTrue(failed)
        self.assertIn("GalleryTests/testClose", report)
        self.assertIn("总用例 1，通过 0，失败 1", report)
        self.assertIn("执行：通过 0，失败 4", report)
        self.assertNotIn("PRIVATE_RUNTIME_VALUE", report)
        self.assertNotIn("<script>", report)

    def test_unfinalized_result_is_not_a_zero_test_pass(self):
        self.bundle(finalized=False)
        (report, failed), run = self.render(payload())
        self.assertTrue(failed)
        self.assertIn("无法读取完整结果", report)
        run.assert_not_called()

    def test_missing_results_do_not_turn_a_successful_step_green(self):
        report, failed = MODULE.render(self.root, {"CI_IPHONE_OUTCOME": "success"})
        self.assertTrue(failed)
        self.assertIn("缺少首次通知授权或完整矩阵", report)
        report, failed = MODULE.render(self.root, {"CI_PREFLIGHT_OUTCOME": "failure",
                                                   "CI_IPHONE_OUTCOME": "skipped"})
        self.assertFalse(failed)  # Preserve preflight failure, do not invent a test failure.
        self.assertIn("没有测试结果包", report)
        self.assertIn("| iPhone | skipped |", report)

    def test_success_requires_permission_and_full_suite_evidence(self):
        self.bundle("Yishu-iPhone-NotificationPermission-fixture.xcresult")
        (report, failed), _ = self.render(payload(), {"CI_IPHONE_OUTCOME": "success"})
        self.assertTrue(failed)
        self.bundle("Yishu-iPhone-fixture.xcresult")
        (_, failed), _ = self.render(payload(), {"CI_IPHONE_OUTCOME": "success"})
        self.assertFalse(failed)

    def test_malformed_or_inconsistent_summaries_fail_closed(self):
        self.bundle()
        variants = [[], {}, payload(), payload(), payload(), payload(), payload()]
        variants[2]["passedTests"] = "1"
        variants[3]["totalTestCount"] = 0
        variants[4]["result"] = "Unknown"
        variants[5]["failedTests"] = 1
        variants[6]["devicesAndConfigurations"][0]["failedTests"] = 1
        for data in variants:
            with self.subTest(data=data):
                (report, failed), _ = self.render(data)
                self.assertTrue(failed)
                self.assertIn("无法读取完整结果", report)

    def test_xcresulttool_timeout_never_exposes_tool_output(self):
        self.bundle()
        error = subprocess.TimeoutExpired("xcrun", 20, output="PRIVATE_RUNTIME_VALUE")
        with patch.object(MODULE.subprocess, "run", side_effect=error):
            report, failed = MODULE.render(self.root, {})
        self.assertTrue(failed)
        self.assertNotIn("PRIVATE_RUNTIME_VALUE", report)

    def test_workflow_collects_independent_evidence_without_masking_failure(self):
        workflow = (ROOT / ".github/workflows/ios-quality.yml").read_text()
        condition = "if: ${{ !cancelled() && steps.preflight.outcome == 'success' }}"
        for title in ("Test iPad pages", "Run Swift compiler analysis and audit Release bundle"):
            step = workflow.split(f"- name: {title}\n", 1)[1].split("\n      - name:", 1)[0]
            self.assertIn(condition, step)
            self.assertNotRegex(step, r"(?m)^\s*continue-on-error:")
        self.assertIn("id: preflight\n        run: Scripts/security-check.sh", workflow)
        self.assertIn("timeout-minutes: 180", workflow)
        self.assertIn("run: python3 Scripts/ci-test-summary.py", workflow)
        self.assertIn("if: failure()", workflow)  # Original diagnostics remain.

    def test_main_appends_summary_without_replacing_other_step_content(self):
        output = self.root / "summary.md"
        output.write_text("Existing evidence\n", encoding="utf-8")
        with patch.dict(MODULE.os.environ, {"CI_RESULT_DIR": str(self.root),
                                           "GITHUB_STEP_SUMMARY": str(output)}, clear=True):
            self.assertEqual(MODULE.main(), 0)
        self.assertTrue(output.read_text().startswith("Existing evidence\n## iOS 验证结果"))

    def test_main_refuses_unresolved_result_root(self):
        with patch.dict(MODULE.os.environ, {"CI_RESULT_DIR": "relative"}, clear=True):
            self.assertEqual(MODULE.main(), 1)


if __name__ == "__main__":
    unittest.main()
