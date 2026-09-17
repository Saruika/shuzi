#!/usr/bin/env python3
"""Validate summaries and CI continuation without spending Actions minutes."""
import importlib.util
import json
import re
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ci_test_summary", ROOT / "Scripts/ci-test-summary.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def validate_preflight(workflow):
    """Fail-closed check of this workflow's two-command literal run step.

    This is deliberately not a general YAML parser. Bound the selected step by
    indentation, then require its current keys and exact commands. A new shell
    or inherited defaults needs explicit review: the current macOS workflow
    relies on Actions' default bash -e to stop after either failed command.
    """
    lines = workflow.splitlines()
    matches = [(index, re.fullmatch(r"( +)id: preflight", line))
               for index, line in enumerate(lines)]
    matches = [(index, match) for index, match in matches if match]
    if len(matches) != 1:
        raise ValueError("Exactly one preflight step is required")
    index, match = matches[0]
    child_indent = len(match.group(1))
    step_indent = child_indent - 2
    if step_indent < 0:
        raise ValueError("Invalid preflight indentation")

    def significant(line):
        return bool(line.strip()) and not line.lstrip().startswith("#")

    def indent(line):
        return len(line) - len(line.lstrip(" "))

    start = index - 1
    while start >= 0 and (not significant(lines[start]) or indent(lines[start]) > step_indent):
        start -= 1
    header_prefix = " " * step_indent + "- name: "
    if start < 0 or not lines[start].startswith(header_prefix):
        raise ValueError("Preflight is not a named step")
    end = index + 1
    while end < len(lines) and (not significant(lines[end]) or indent(lines[end]) > step_indent):
        end += 1
    step = [line.rstrip() for line in lines[start:end] if significant(line)]
    child = " " * child_indent
    commands = ("Scripts/security-check.sh", "python3 Scripts/test-content-identifier-optimization.py")
    expected = [lines[start], child + "id: preflight", child + "run: |",
                *(child + "  " + command for command in commands)]
    if step != expected:
        raise ValueError("Preflight must run both exact checks, in order, without failure masking")
    # An inherited custom shell may omit -e even when the literal commands look
    # correct. No defaults currently exist; review any future addition explicitly.
    if re.search(r"(?m)^\s*defaults:", workflow):
        raise ValueError("Inherited run defaults require explicit fail-fast validation")
    if re.search(r"(?m)^ {" + str(max(0, step_indent - 2)) + r"}continue-on-error:", workflow):
        raise ValueError("The containing quality job must not ignore failures")


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
        validate_preflight(workflow)
        commands = "          Scripts/security-check.sh\n          python3 Scripts/test-content-identifier-optimization.py"
        self.assertIn(commands, workflow)
        mutations = {
            "reversed": workflow.replace(commands, "\n".join(reversed(commands.splitlines())), 1),
            "security-failure-masked": workflow.replace("          Scripts/security-check.sh\n", "          Scripts/security-check.sh || true\n", 1),
            "optimizer-failure-masked": workflow.replace("          python3 Scripts/test-content-identifier-optimization.py\n", "          python3 Scripts/test-content-identifier-optimization.py || true\n", 1),
            "errexit-disabled": workflow.replace(commands, "          set +e\n" + commands, 1),
            "step-ignores-failure": workflow.replace("        id: preflight\n", "        id: preflight\n        continue-on-error: true\n", 1),
            "custom-shell": workflow.replace("        id: preflight\n", "        id: preflight\n        shell: bash {0}\n", 1),
            "detached-optimizer-step": workflow.replace(commands, "          Scripts/security-check.sh\n      - name: Detached optimizer\n        run: |\n          python3 Scripts/test-content-identifier-optimization.py", 1),
            "inherited-shell": "defaults:\n  run:\n    shell: bash {0}\n" + workflow,
            "job-ignores-failure": workflow.replace("    timeout-minutes: 180\n", "    timeout-minutes: 180\n    continue-on-error: true\n", 1),
        }
        for category, altered in mutations.items():
            with self.subTest(preflight_contract=category), self.assertRaises(ValueError):
                validate_preflight(altered)
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
