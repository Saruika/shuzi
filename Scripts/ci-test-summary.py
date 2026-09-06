#!/usr/bin/env python3
"""Summarize xcresult evidence without copying assertions, account data or logs."""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

OUTCOMES = {"success", "failure", "cancelled", "skipped"}
IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*(?:/[A-Za-z_][A-Za-z0-9_]*(?:\(\))?){1,2}")


def count(data: dict, field: str) -> int:
    value = data.get(field)
    if type(value) is not int or value < 0:
        raise ValueError("invalid count")
    return value


def bundle_summary(bundle: Path) -> tuple[list[str], bool]:
    # A missing Info.plist is commonly an interrupted/unfinalized run, not a
    # successful zero-test run. Never overwrite, finalize or repair the bundle.
    if not (bundle / "Info.plist").is_file():
        raise ValueError("unfinalized bundle")
    result = subprocess.run(
        ["/usr/bin/xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle), "--compact"],
        capture_output=True, text=True, timeout=20, check=True,
    )
    data = json.loads(result.stdout)
    if not isinstance(data, dict) or data.get("result") not in {"Passed", "Failed", "Skipped"}:
        raise ValueError("unknown result")
    counts = [count(data, field) for field in ("totalTestCount", "passedTests", "failedTests", "skippedTests")]
    if data["result"] == "Passed" and (counts[0] == 0 or counts[2] > 0):
        raise ValueError("inconsistent success")
    lines = [f"Xcode 摘要：{data['result']}；总用例 {counts[0]}，通过 {counts[1]}，失败 {counts[2]}，跳过 {counts[3]}。"]
    configurations = data.get("devicesAndConfigurations", [])
    if not isinstance(configurations, list):
        raise ValueError("invalid configurations")
    if configurations:
        executions = [sum(count(row, field) for row in configurations)
                      for field in ("passedTests", "failedTests", "skippedTests")]
        if data["result"] == "Passed" and executions[1] > 0:
            raise ValueError("inconsistent configuration success")
        lines += [f"设备/参数化执行：通过 {executions[0]}，失败 {executions[1]}，跳过 {executions[2]}（不与上行相加）。"]
    failures = data.get("testFailures", [])
    if not isinstance(failures, list):
        raise ValueError("invalid failures")
    # Only static Swift test identifiers are allowed. failureText, testName,
    # assertion values and device names can contain runtime/private data.
    identifiers = sorted({entry.get("testIdentifierString", "") for entry in failures
                          if isinstance(entry, dict) and isinstance(entry.get("testIdentifierString"), str)
                          and len(entry["testIdentifierString"]) <= 240
                          and IDENTIFIER.fullmatch(entry["testIdentifierString"])})
    if identifiers:
        lines += ["", "失败用例：", "", *[f"- `{name}`" for name in identifiers[:80]]]
    if len(failures) > len(identifiers):
        lines += ["", "部分重复或非标准失败标识未展开；详细诊断请查看 xcresult 附件。"]
    return lines, data["result"] == "Failed" or counts[2] > 0


def render(root: Path, environment: dict[str, str]) -> tuple[str, bool]:
    lines = ["## iOS 验证结果", "", "| 阶段 | 实际步骤结果 |", "| --- | --- |"]
    outcomes = {}
    for key, title in (("PREFLIGHT", "前置检查"), ("IPHONE", "iPhone"), ("IPAD", "iPad"), ("RELEASE", "Release 分析与包检查")):
        value = environment.get(f"CI_{key}_OUTCOME", "")
        outcomes[key] = value if value in OUTCOMES else "未取得结果"
        lines.append(f"| {title} | {outcomes[key]} |")
    lines += ["", "skipped / cancelled / 未取得结果均不代表通过。某项失败后继续采集其他阶段，不改变原始失败结论。"]
    bundles = sorted(root.glob("*.xcresult"))
    incomplete = False
    for bundle in bundles[:12]:
        # Restrict filenames too: never embed arbitrary Markdown/HTML or data
        # supplied through a filesystem name into a GitHub summary.
        name = bundle.name if re.fullmatch(r"[A-Za-z0-9_.-]{1,180}", bundle.name) else "未展示的结果包名称"
        lines += ["", f"### {name}", ""]
        try:
            details, failed = bundle_summary(bundle)
            lines += details
            incomplete = incomplete or failed
        except (OSError, ValueError, TypeError, AttributeError, subprocess.SubprocessError):
            incomplete = True
            lines += ["无法读取完整结果；可能中断或格式不匹配，不计为通过。原件保留。"]
    if len(bundles) > 12:
        incomplete = True
        lines += ["", "结果包数量异常，仅展示前 12 个；需检查原始附件。"]
    for family, key in (("iPhone", "IPHONE"), ("iPad", "IPAD")):
        if outcomes[key] == "success":
            family_bundles = [b for b in bundles if b.name.startswith(f"Yishu-{family}-")]
            permission = [b for b in family_bundles if b.name.startswith(f"Yishu-{family}-NotificationPermission-")]
            if not permission or len(family_bundles) == len(permission):
                incomplete = True
                lines += ["", f"{family} 步骤报告成功，但缺少首次通知授权或完整矩阵的结果包，证据不完整。"]
    if not bundles:
        lines += ["", "没有测试结果包；请先查看前置检查、构建或模拟器启动步骤，不能认定页面测试通过。"]
    lines += ["", "原始失败保留在工作流日志及 yishu-xcresults 附件；此摘要不复制断言正文、截图内容或账号数据。", ""]
    return "\n".join(lines), incomplete


def main() -> int:
    root_value = os.environ.get("CI_RESULT_DIR", "")
    if not root_value or not Path(root_value).is_absolute():
        print("ci-test-summary: absolute CI_RESULT_DIR required", file=sys.stderr)
        return 1
    report, incomplete = render(Path(root_value), dict(os.environ))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with Path(summary).open("a", encoding="utf-8") as stream:
            stream.write(report)
    else:
        print(report)
    return int(incomplete)


if __name__ == "__main__":
    raise SystemExit(main())
