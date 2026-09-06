#!/usr/bin/env python3
"""Exercise CI simulator ownership/order without booting or erasing a device."""
import json
import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = "11111111-1111-4111-8111-111111111111"
CREATED = "22222222-2222-4222-8222-222222222222"
STARTUP = "YishuUITests/YishuUITests/testStartupAsksSystemNotificationPermissionBeforeLogin"
MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["CI_TEST_LOG"], "a") as log:
    log.write(json.dumps([tool, args]) + "\n")
template = "11111111-1111-4111-8111-111111111111"
created = "22222222-2222-4222-8222-222222222222"
family = os.environ.get("CI_TEST_FAMILY", "iPhone")
if tool == "uuidgen":
    print(created)
elif tool == "xcrun" and args[:3] == ["simctl", "list", "devices"]:
    print(json.dumps({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-2": [{
        "udid": template, "isAvailable": True,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType." + family
    }]}}))
elif tool == "xcrun" and args[:2] == ["simctl", "create"]:
    print(created)
elif tool == "xcodebuild" and "-showdestinations" in args:
    print("{ platform:iOS Simulator, arch:arm64, id:" + template +
          ", OS:26.2, name:" + family + (" 17 Pro Max" if family == "iPhone" else " Pro 13-inch") + " }")
elif tool == "xcodebuild":
    marker = pathlib.Path(os.environ["CI_TEST_COUNT"])
    count = int(marker.read_text()) + 1 if marker.exists() else 1
    marker.write_text(str(count))
    if str(count) == os.environ.get("CI_TEST_FAIL_AT"):
        sys.exit(65)
'''


def run_case(family: str, fail_at: str = "") -> None:
    with tempfile.TemporaryDirectory(prefix="ci-permission-contract-") as temporary:
        directory = Path(temporary)
        binaries = directory / "bin"
        binaries.mkdir()
        for name in ("xcrun", "xcodebuild", "uuidgen"):
            mock = binaries / name
            mock.write_text(MOCK)
            mock.chmod(0o700)
        log = directory / "calls.jsonl"
        environment = dict(os.environ, PATH=f"{binaries}:{os.environ['PATH']}",
                           RUNNER_TEMP=temporary, CI_RESULT_DIR=str(directory / "results"),
                           CI_TEST_LOG=str(log), CI_TEST_COUNT=str(directory / "count"),
                           CI_TEST_FAMILY=family, CI_TEST_FAIL_AT=fail_at)
        result = subprocess.run(["bash", "Scripts/ci-ios-tests.sh", family], cwd=ROOT,
                                env=environment, capture_output=True, text=True, timeout=15)
        assert result.returncode == (65 if fail_at else 0), result.stderr
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        tests = [args for tool, args in calls if tool == "xcodebuild" and "test" in args]
        assert len(tests) == (1 if fail_at == "1" else 2), tests
        assert f"-only-testing:{STARTUP}" in tests[0]
        for invocation in tests:
            assert invocation[invocation.index("-destination") + 1] == f"platform=iOS Simulator,id={CREATED}"
            assert "-enableCodeCoverage" in invocation
            assert invocation[invocation.index("-parallel-testing-enabled") + 1] == "NO"
        if len(tests) == 2:
            assert f"-skip-testing:{STARTUP}" in tests[1]
            assert not any(arg.startswith("-only-testing:") for arg in tests[1]), "full suite was narrowed"
            assert sum(arg.startswith("-skip-testing:") for arg in tests[1]) == 1
            assert tests[0][tests[0].index("-derivedDataPath") + 1] == tests[1][tests[1].index("-derivedDataPath") + 1]
            assert tests[0][tests[0].index("-resultBundlePath") + 1] != tests[1][tests[1].index("-resultBundlePath") + 1]
        deleted = [args for tool, args in calls if tool == "xcrun" and args[:2] == ["simctl", "delete"]]
        assert deleted == [["simctl", "delete", CREATED]], deleted
        assert not any(tool == "xcrun" and args[:2] in (["simctl", "erase"], ["simctl", "shutdown"])
                       and TEMPLATE in args for tool, args in calls)


if __name__ == "__main__":
    for device_family in ("iPhone", "iPad"):
        for failure in ("", "1", "2"):
            run_case(device_family, failure)
    print("ci-permission-isolation: both families, same fresh device, full coverage and failure cleanup passed")
