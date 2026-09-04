import hashlib
import json
import re
import shlex
import stat
import subprocess
import tempfile
from pathlib import Path


DEPLOYER = Path("Server/operations/deploy-shuzijun-health-monitor")
DEPLOYER_CONTRACT = Path("Server/tests/health-monitor-deployer-contract-test.py")
HEALTH_SCRIPT = Path("Server/operations/shuzijun-internal-health")
HEALTH_SERVICE = Path("Server/operations/shuzijun-internal-health.service")
HEALTH_TIMER = Path("Server/operations/shuzijun-internal-health.timer")
INTERNAL_HEALTH_TEST = Path("Server/tests/internal-health-contract-test.py")
PRIVATE_LOG_CONFIG = Path("Server/operations/shuzijun-private-logs.conf")
SNAPSHOT_CRON = Path("Server/operations/tencent-daily-snapshot.cron")
RELEASE = Path("Server/releases/v1.3.30-build42.14.md")


def line_number(lines: list[str], fragment: str, start: int = 0) -> int:
    for index in range(start, len(lines)):
        if fragment in lines[index]:
            return index
    raise AssertionError(f"missing required transaction step: {fragment}")


def function_body(lines: list[str], name: str, next_name: str) -> str:
    start = line_number(lines, f"{name}() {{")
    end = line_number(lines, f"{next_name}() {{", start + 1)
    return "\n".join(lines[start:end])


def assert_validator_negative_path(validator: str) -> None:
    harness = f"""
set -Eeuo pipefail
VALIDATED_INVOCATION=
VALIDATED_EXIT_STATUS=
unit_value() {{
    case "$2" in
        InvocationID) printf '%s\\n' new-invocation ;;
        Result) printf '%s\\n' success ;;
        ExecMainStatus) printf '%s\\n' 2 ;;
        ActiveState) printf '%s\\n' inactive ;;
        SubState) printf '%s\\n' dead ;;
        *) return 70 ;;
    esac
}}
service_usec() {{
    case "$1" in
        ExecMainStartTimestamp) printf '%s\\n' 1000 ;;
        ExecMainExitTimestamp) printf '%s\\n' 1100 ;;
        ExecMainStartTimestampMonotonic) printf '%s\\n' 2000 ;;
        ExecMainExitTimestampMonotonic) printf '%s\\n' 2100 ;;
        *) return 71 ;;
    esac
}}
validate_status() {{ return 23; }}
{validator}
if validate_last_invocation 1 old-sha previous-invocation 900000 1200000 1900000 2200000; then
    exit 90
fi
[[ -z "$VALIDATED_INVOCATION" ]]
"""
    subprocess.run(["/bin/bash", "-c", harness], check=True)


def assert_validator_exit_status_contract(validator: str) -> None:
    for main_status, expected_status_exit, should_pass in (
        (0, 0, True),
        (2, 2, True),
        (0, 2, False),
        (2, 0, False),
        (1, 1, False),
    ):
        invocation = (
            "validate_last_invocation 1 old-sha previous-invocation "
            "900000 1200000 1900000 2200000"
        )
        expectation = invocation if should_pass else f"if {invocation}; then exit 91; fi"
        harness = f"""
set -Eeuo pipefail
MAIN_STATUS={main_status}
EXPECTED_STATUS_EXIT={expected_status_exit}
VALIDATED_INVOCATION=
VALIDATED_EXIT_STATUS=
unit_value() {{
    case "$2" in
        InvocationID) printf '%s\\n' new-invocation ;;
        Result) printf '%s\\n' success ;;
        ExecMainStatus) printf '%s\\n' "$MAIN_STATUS" ;;
        ActiveState) printf '%s\\n' inactive ;;
        SubState) printf '%s\\n' dead ;;
        *) return 70 ;;
    esac
}}
service_usec() {{
    case "$1" in
        ExecMainStartTimestamp) printf '%s\\n' 1000 ;;
        ExecMainExitTimestamp) printf '%s\\n' 1100 ;;
        ExecMainStartTimestampMonotonic) printf '%s\\n' 2000 ;;
        ExecMainExitTimestampMonotonic) printf '%s\\n' 2100 ;;
        *) return 71 ;;
    esac
}}
validate_status() {{ [[ "$5" == "$EXPECTED_STATUS_EXIT" ]]; }}
{validator}
{expectation}
if [[ {str(should_pass).lower()} == true ]]; then
    [[ "$VALIDATED_INVOCATION" == new-invocation ]]
    [[ "$VALIDATED_EXIT_STATUS" == "$MAIN_STATUS" ]]
else
    [[ -z "$VALIDATED_INVOCATION" ]]
    [[ -z "$VALIDATED_EXIT_STATUS" ]]
fi
"""
        subprocess.run(["/bin/bash", "-c", harness], check=True)


def assert_status_boundary_negative_path(require_status: str) -> None:
    harness = f"""
set -Eeuo pipefail
STATUS_DIR=/does/not/matter
STATUS_FILE=/does/not/matter/status.json
require_dir() {{ return 19; }}
require_safe_parent() {{ return 0; }}
{require_status}
if require_status; then
    exit 91
fi
"""
    subprocess.run(["/bin/bash", "-c", harness], check=True)


def assert_crontab_transform_contract(transform: str) -> None:
    old_line = (
        "31 3 * * * flock -xn /run/tencent-snapshot.lock -c "
        "/usr/local/sbin/tencent-daily-snapshot "
        ">>/var/log/tencent-snapshot.log 2>&1"
    )
    with tempfile.TemporaryDirectory(prefix="sj-crontab-transform-") as temporary:
        source = Path(temporary) / "source"
        destination = Path(temporary) / "destination"
        original = (
            b"*/5 * * * * /usr/local/qcloud/stargate --quiet\n"
            + old_line.encode("utf-8")
            + b"\nMAILTO=ops@example.invalid"
        )
        source.write_bytes(original)
        harness = f"""
set -Eeuo pipefail
OLD_SNAPSHOT_CRON_LINE={shlex.quote(old_line)}
sha() {{ shasum -a 256 "$1" | cut -d' ' -f1; }}
require_file() {{ return 0; }}
chown() {{ return 0; }}
chmod() {{ return 0; }}
{transform}
transform_root_crontab {shlex.quote(str(source))} {shlex.quote(str(destination))}
[[ "$REMOVED_SNAPSHOT_LINES" == 1 ]]
"""
        subprocess.run(["/bin/bash", "-c", harness], check=True)
        assert destination.read_bytes() == (
            b"*/5 * * * * /usr/local/qcloud/stargate --quiet\n"
            b"MAILTO=ops@example.invalid"
        )

        migrated = Path(temporary) / "migrated"
        migrated_output = Path(temporary) / "migrated-output"
        migrated.write_bytes(
            original.replace(old_line.encode("utf-8") + b"\n", b"")
        )
        migrated_harness = harness.replace(
            shlex.quote(str(source)), shlex.quote(str(migrated))
        ).replace(
            shlex.quote(str(destination)), shlex.quote(str(migrated_output))
        ).replace(
            '[[ "$REMOVED_SNAPSHOT_LINES" == 1 ]]',
            '[[ "$REMOVED_SNAPSHOT_LINES" == 0 ]]',
        )
        subprocess.run(["/bin/bash", "-c", migrated_harness], check=True)
        assert migrated_output.read_bytes() == migrated.read_bytes()

        duplicate = Path(temporary) / "duplicate"
        duplicate_output = Path(temporary) / "duplicate-output"
        duplicate.write_bytes((old_line + "\n" + old_line + "\n").encode("utf-8"))
        duplicate_harness = harness.replace(
            shlex.quote(str(source)), shlex.quote(str(duplicate))
        ).replace(shlex.quote(str(destination)), shlex.quote(str(duplicate_output)))
        result = subprocess.run(
            ["/bin/bash", "-c", duplicate_harness],
            capture_output=True,
            text=True,
            check=False,
        )
        assert result.returncode != 0
        assert not duplicate_output.exists()


def assert_snapshot_migration_source_contract(gate: str) -> None:
    for removed, old_state, old_sha, target_exact, should_pass in (
        (1, "absent", "", False, True),
        (1, "present", "unexpected", True, True),
        (0, "present", "expected-snapshot-sha", True, True),
        (0, "present", "expected-snapshot-sha", False, False),
        (0, "absent", "", True, False),
        (0, "present", "unexpected", True, False),
        (-1, "present", "expected-snapshot-sha", True, False),
        (2, "present", "expected-snapshot-sha", True, False),
    ):
        invocation = "require_snapshot_migration_source"
        expectation = (
            invocation if should_pass else f"if {invocation}; then exit 90; fi"
        )
        harness = f"""
set -Eeuo pipefail
REMOVED_SNAPSHOT_LINES={removed}
OLD_SNAPSHOT_CRON_STATE={shlex.quote(old_state)}
OLD_SNAPSHOT_CRON_SHA={shlex.quote(old_sha)}
TARGET_EXACT={str(target_exact).lower()}
SNAPSHOT_CRON_TARGET=/etc/cron.d/tencent-daily-snapshot
NEW_SNAPSHOT_CRON_SHA=expected-snapshot-sha
REQUIRE_FILE_CALLS=0
require_file() {{
    REQUIRE_FILE_CALLS=$((REQUIRE_FILE_CALLS + 1))
    [[ "$1" == "$SNAPSHOT_CRON_TARGET" && "$2" == 644 && "$3" == "$NEW_SNAPSHOT_CRON_SHA" ]]
    [[ "$TARGET_EXACT" == true ]]
}}
{gate}
{expectation}
if [[ "$REMOVED_SNAPSHOT_LINES" == 0 ]]; then
    if [[ "$OLD_SNAPSHOT_CRON_STATE" == present && "$OLD_SNAPSHOT_CRON_SHA" == "$NEW_SNAPSHOT_CRON_SHA" ]]; then
        (( REQUIRE_FILE_CALLS == 1 ))
    else
        (( REQUIRE_FILE_CALLS == 0 ))
    fi
else
    (( REQUIRE_FILE_CALLS == 0 ))
fi
"""
        subprocess.run(["/bin/bash", "-c", harness], check=True)


def assert_snapshot_lock_busy_zero_mutation(acquire_lock: str) -> None:
    instrumented = acquire_lock.replace(
        "/usr/bin/flock -n 8", "mock_flock -n 8"
    )
    with tempfile.TemporaryDirectory(prefix="sj-snapshot-lock-busy-") as temporary:
        lock = Path(temporary) / "snapshot.lock"
        mutation = Path(temporary) / "mutation"
        lock.write_bytes(b"existing-lock-bytes\n")
        harness = f"""
set -Eeuo pipefail
SNAPSHOT_EXECUTION_LOCK={shlex.quote(str(lock))}
ROOT_BASHPID=$$
MUTATION={shlex.quote(str(mutation))}
require_snapshot_execution_lock_file() {{ return 0; }}
mock_flock() {{ return 73; }}
chown() {{ : > "$MUTATION"; return 0; }}
chmod() {{ : > "$MUTATION"; return 0; }}
sync() {{ : > "$MUTATION"; return 0; }}
stat() {{ return 74; }}
{instrumented}
if acquire_snapshot_execution_lock; then
    exit 90
fi
[[ ! -e "$MUTATION" ]]
"""
        result = subprocess.run(
            ["/bin/bash", "-c", harness], capture_output=True, text=True, check=False
        )
        assert result.returncode == 0, result.stderr
        assert "snapshot execution lock busy" in result.stderr
        assert lock.read_bytes() == b"existing-lock-bytes\n"


def assert_snapshot_lock_cross_window_rollback(
    acquire_lock: str, restore_private_logs: str
) -> None:
    instrumented = acquire_lock.replace(
        "/usr/bin/flock -n 8", "mock_flock -n 8"
    )
    with tempfile.TemporaryDirectory(prefix="sj-snapshot-lock-window-") as temporary:
        root = Path(temporary)
        lock = root / "snapshot.lock"
        private_logs = root / "private-logs"
        lock.write_bytes(b"")
        private_logs.mkdir(mode=0o700)
        for name in ("sync-authority.log", "sync-standby.log", "snapshot.log"):
            (private_logs / name).write_bytes(b"")
        harness = f"""
set -Eeuo pipefail
SNAPSHOT_EXECUTION_LOCK={shlex.quote(str(lock))}
ROOT_BASHPID=$$
LOCK_HELD=0
PRIVATE_LOG_DIR={shlex.quote(str(private_logs))}
AUTHORITY_LOG="$PRIVATE_LOG_DIR/sync-authority.log"
STANDBY_LOG="$PRIVATE_LOG_DIR/sync-standby.log"
SNAPSHOT_LOG="$PRIVATE_LOG_DIR/snapshot.log"
OLD_PRIVATE_LOG_STATE=absent
require_snapshot_execution_lock_file() {{ return 0; }}
mock_flock() {{
    if (( LOCK_HELD == 0 )); then
        LOCK_HELD=1
        return 0
    fi
    return 75
}}
stat() {{ printf '%s\\n' '1:2'; }}
require_dir() {{ return 0; }}
require_private_log_file() {{ [[ -f "$1" && ! -s "$1" ]]; }}
sync_path() {{ return 0; }}
{instrumented}
{restore_private_logs}
acquire_snapshot_execution_lock
# Cron opens its redirect before flock. While the deployer owns the lock the
# non-blocking snapshot command must skip without appending any log content.
: >> "$SNAPSHOT_LOG"
if mock_flock -xn "$SNAPSHOT_EXECUTION_LOCK"; then
    printf 'unexpected snapshot output\\n' >> "$SNAPSHOT_LOG"
fi
[[ ! -s "$SNAPSHOT_LOG" ]]
restore_private_log_state
[[ ! -e "$PRIVATE_LOG_DIR" ]]
"""
        subprocess.run(["/bin/bash", "-c", harness], check=True)


def assert_old_loaded_definition_negative_paths(old_loaded: str) -> None:
    runtime = old_loaded.replace(
        '/usr/bin/python3 -I "$ROLE_VERIFY" "$ROLE" || return 1',
        'verify_role "$ROLE" || return 1',
    )
    for drift, timer_state, timer_substate, service_state, service_substate, expected_timer, service_policy, timer_policy, should_pass in (
        ("none", "active", "waiting", "failed", "failed", "active", "inactive-or-failed", "strict", True),
        ("none", "active", "elapsed", "inactive", "dead", "active", "inactive-or-failed", "preflight", True),
        ("none", "active", "elapsed", "inactive", "dead", "active", "inactive-or-failed", "strict", False),
        ("none", "active", "running", "inactive", "dead", "active", "inactive-or-failed", "preflight", False),
        ("exec", "active", "waiting", "failed", "failed", "active", "inactive-or-failed", "strict", False),
        ("flags", "active", "waiting", "failed", "failed", "active", "inactive-or-failed", "strict", False),
        ("reload", "active", "waiting", "failed", "failed", "active", "inactive-or-failed", "strict", False),
        ("timer-unit", "active", "waiting", "failed", "failed", "active", "inactive-or-failed", "strict", False),
        ("success-status", "active", "waiting", "failed", "failed", "active", "inactive-or-failed", "strict", False),
        ("none", "inactive", "dead", "inactive", "dead", "inactive", "inactive", "strict", True),
        ("none", "inactive", "dead", "failed", "failed", "inactive", "inactive", "strict", False),
    ):
        invocation = f"require_old_runtime_loaded {expected_timer} {service_policy} {timer_policy}"
        expectation = (
            invocation
            if should_pass
            else f"if {invocation}; then exit 92; fi"
        )
        harness = f"""
set -Eeuo pipefail
DRIFT={drift}
TIMER_STATE={timer_state}
TIMER_SUBSTATE={timer_substate}
SERVICE_STATE={service_state}
SERVICE_SUBSTATE={service_substate}
ROLE=standby
ROLE_VERIFY=/not-used/role
ROLE_VERIFY_SHA=role-sha
SERVICE_TARGET=/etc/systemd/system/shuzijun-internal-health.service
TIMER_TARGET=/etc/systemd/system/shuzijun-internal-health.timer
SERVICE_OBJECT_PATH=/org/freedesktop/systemd1/unit/shuzijun_2dinternal_2dhealth_2eservice
require_frozen_files() {{ return 0; }}
require_file() {{ return 0; }}
verify_role() {{ return 0; }}
systemd-analyze() {{ return 0; }}
require_exact_exec_start() {{ [[ "$DRIFT" != exec && "$DRIFT" != flags ]]; }}
require_service_execution_context() {{ return 0; }}
unit_value() {{
    local unit=$1 property=$2
    case "$property" in
        LoadState) printf '%s\\n' loaded ;;
        ActiveState)
            [[ "$unit" == *.timer ]] && printf '%s\\n' "$TIMER_STATE" || printf '%s\\n' "$SERVICE_STATE"
            ;;
        SubState)
            [[ "$unit" == *.timer ]] && printf '%s\\n' "$TIMER_SUBSTATE" || printf '%s\\n' "$SERVICE_SUBSTATE"
            ;;
        Job|DropInPaths|ExecCondition|ExecStartPre|ExecStartPost|ExecReload|ExecStop|ExecStopPost)
            printf '\\n'
            ;;
        SuccessExitStatus)
            [[ "$DRIFT" == success-status ]] && printf '0\\n' || printf '2\\n'
            ;;
        Unit)
            [[ "$DRIFT" == timer-unit ]] && printf '%s\\n' untrusted.service || printf '%s\\n' shuzijun-internal-health.service
            ;;
        NeedDaemonReload)
            [[ "$DRIFT" == reload && "$unit" == *.timer ]] && printf '%s\\n' yes || printf '%s\\n' no
            ;;
        Type) printf '%s\\n' oneshot ;;
        Result) printf '%s\\n' exit-code ;;
        ExecMainStatus) printf '%s\\n' 1 ;;
        FragmentPath)
            [[ "$unit" == *.timer ]] && printf '%s\\n' "$TIMER_TARGET" || printf '%s\\n' "$SERVICE_TARGET"
            ;;
        ExecStart)
            [[ "$DRIFT" == exec ]] && printf '%s\\n' '{{ argv[]=/usr/local/sbin/untrusted ; }}' || printf '%s\\n' '{{ argv[]=/usr/local/sbin/shuzijun-internal-health ; }}'
            ;;
        *) return 70 ;;
    esac
}}
{runtime}
{expectation}
"""
        subprocess.run(["/bin/bash", "-c", harness], check=True)


def assert_exact_exec_start_contract(exact_exec: str) -> None:
    script = "/usr/local/sbin/shuzijun-internal-health"
    python = "/usr/bin/python3"

    def payload(path: str, argv: list[str], flags: list[str], count: int = 1) -> dict:
        entry = [path, argv, flags, 0, 0, 0, 0, 0, 0, 0]
        return {"type": "a(sasasttttuii)", "data": [entry for _ in range(count)]}

    cases = [
        (script, [script], payload(script, [script], []), True),
        (script, [script], payload("/usr/local/sbin/untrusted", [script], []), False),
        (script, [script], payload(script, [script, "--extra"], []), False),
        (script, [script], payload(script, [script], [], count=2), False),
        (script, [script], payload(script, [script], ["fully-privileged"]), False),
        (script, [script], payload(script, [script], ["no-setuid"]), False),
        (script, [script], payload(script, [script], ["ambient"]), False),
        (script, [script], payload(script, [script], ["no-env-expand"]), False),
        (script, [script], payload(script, [script], ["ignore-failure"]), False),
        (python, [python, "-I", script], payload(python, [python, "-I", script], []), True),
        (
            python,
            [python, "-I", script],
            payload(python, [f"{python} -I", script], []),
            False,
        ),
    ]
    for expected_path, expected_argv, value, should_pass in cases:
        invocation = " ".join(
            shlex.quote(part)
            for part in [
                "require_exact_exec_start",
                "/org/freedesktop/systemd1/unit/test",
                expected_path,
                *expected_argv,
            ]
        )
        expectation = invocation if should_pass else f"if {invocation}; then exit 93; fi"
        harness = f"""
set -Eeuo pipefail
EXEC_JSON={shlex.quote(json.dumps(value, separators=(",", ":")))}
exec_start_ex_json() {{ printf '%s\\n' "$EXEC_JSON"; }}
{exact_exec}
{expectation}
"""
        subprocess.run(["/bin/bash", "-c", harness], check=True)


def assert_service_execution_context_negative_paths(service_context: str) -> None:
    baseline = {
        "User": "root",
        "Group": "root",
        "Environment": "",
        "EnvironmentFiles": "",
        "PassEnvironment": "",
        "UnsetEnvironment": "",
        "WorkingDirectory": "",
        "RootDirectory": "",
        "RootImage": "",
        "ExecSearchPath": "",
    }
    cases = [(None, "", True)] + [
        ("User", "untrusted", False),
        ("Group", "untrusted", False),
        ("Environment", "PATH=/untrusted", False),
        ("EnvironmentFiles", "/etc/untrusted.env", False),
        ("PassEnvironment", "PYTHONPATH", False),
        ("UnsetEnvironment", "PATH", False),
        ("WorkingDirectory", "/tmp", False),
        ("RootDirectory", "/srv/chroot", False),
        ("RootImage", "/srv/root.img", False),
        ("ExecSearchPath", "/untrusted", False),
    ]
    for property_name, drift_value, should_pass in cases:
        values = dict(baseline)
        if property_name is not None:
            values[property_name] = drift_value
        case_arms = "\n".join(
            f"        {name}) printf '%s\\n' {shlex.quote(value)} ;;"
            for name, value in values.items()
        )
        invocation = (
            "require_service_execution_context "
            "shuzijun-internal-health.service"
        )
        expectation = invocation if should_pass else f"if {invocation}; then exit 94; fi"
        harness = f"""
set -Eeuo pipefail
unit_value() {{
    [[ "$1" == shuzijun-internal-health.service ]] || return 70
    case "$2" in
{case_arms}
        *) return 71 ;;
    esac
}}
{service_context}
{expectation}
"""
        subprocess.run(["/bin/bash", "-c", harness], check=True)


def assert_main_immediate_timer_fire_path(timer_start: str) -> None:
    harness = f"""
set -Eeuo pipefail
timer_enabled=0
timer_active=0
service_busy=0
require_timer_disabled_link() {{ return 0; }}
timer_usec() {{ exit 95; }}
settle_timer_schedule() {{
    (( service_busy == 1 )) || return 96
    service_busy=0
    SETTLED_INVOCATION=settled-invocation
    SETTLED_TIMER_TRIGGER=4242
    return 0
}}
systemctl() {{
    case "$1" in
        is-enabled)
            (( timer_enabled == 0 )) && printf '%s\\n' disabled || printf '%s\\n' enabled
            ;;
        start)
            [[ "$2" == shuzijun-internal-health.timer ]] || return 97
            timer_active=1
            service_busy=1
            ;;
        is-active)
            [[ "$2" == shuzijun-internal-health.timer ]] || return 98
            (( timer_active == 1 )) && printf '%s\\n' active || printf '%s\\n' inactive
            ;;
        *) return 99 ;;
    esac
}}
{timer_start}
start_disabled_timer_and_settle
[[ "$SETTLED_INVOCATION" == settled-invocation && "$SETTLED_TIMER_TRIGGER" == 4242 ]]
"""
    subprocess.run(["/bin/bash", "-c", harness], check=True)


def assert_timer_activation_evidence_contract(classifier: str) -> None:
    harness = f"""
set -Eeuo pipefail
{classifier}
classify_timer_activation_evidence old-sha 100 old-sha 100
[[ "$TIMER_ACTIVATION_EVIDENCE" == unchanged ]]
classify_timer_activation_evidence old-sha 100 new-sha 101
[[ "$TIMER_ACTIVATION_EVIDENCE" == invoked ]]
for candidate in \
    'new-sha 100' \
    'old-sha 101'; do
    read -r digest inode <<< "$candidate"
    if classify_timer_activation_evidence old-sha 100 "$digest" "$inode"; then
        exit 95
    fi
    [[ -z "$TIMER_ACTIVATION_EVIDENCE" ]]
done
"""
    subprocess.run(["/bin/bash", "-c", harness], check=True)


def assert_old_state_stability_retry(stable: str) -> None:
    harness = f"""
set -Eeuo pipefail
checks=0
wait_health_idle() {{ return 0; }}
require_old_state() {{
    checks=$((checks + 1))
    (( checks >= 2 ))
}}
sleep() {{ return 0; }}
{stable}
require_old_state_stable
(( checks == 3 ))
"""
    subprocess.run(["/bin/bash", "-c", harness], check=True)

    negative = f"""
set -Eeuo pipefail
wait_health_idle() {{ return 0; }}
require_old_state() {{ return 1; }}
sleep() {{ return 0; }}
seq() {{ printf '1\n2\n'; }}
{stable}
if require_old_state_stable; then
    exit 96
fi
"""
    subprocess.run(["/bin/bash", "-c", negative], check=True)


def assert_systemctl_unit_intent_contract(intent: str) -> None:
    for action, rc, should_pass in (
        ("stop", 0, True),
        ("stop", 5, True),
        ("stop", 1, False),
        ("stop", 4, False),
        ("stop", 6, False),
        ("reset-failed", 0, True),
        ("reset-failed", 1, True),
        ("reset-failed", 5, True),
        ("reset-failed", 4, False),
        ("reset-failed", 6, False),
    ):
        invocation = f"run_systemctl_unit_intent {action}"
        expectation = (
            invocation if should_pass else f"if {invocation}; then exit 97; fi"
        )
        harness = f"""
set -Eeuo pipefail
SYSTEMCTL_RC={rc}
systemctl() {{
    [[ "$1" == {action} && "$2" == shuzijun-internal-health.service ]]
    return "$SYSTEMCTL_RC"
}}
{intent}
{expectation}
"""
        subprocess.run(["/bin/bash", "-c", harness], check=True)


def assert_isolate_health_runtime_contract(
    isolate: str, intent: str
) -> None:
    for stop_rc, reset_rc, files_trusted, reload_rc, mode, sleep_rc, should_pass in (
        (5, 1, True, 0, "transient", 0, True),
        (5, 5, True, 0, "transient", 0, True),
        (0, 0, True, 0, "loaded", 0, True),
        (1, 0, True, 0, "loaded", 0, False),
        (0, 4, True, 0, "loaded", 0, False),
        (5, 5, False, 0, "loaded", 0, False),
        (5, 5, True, 1, "loaded", 0, False),
        (5, 5, True, 0, "unstable", 0, False),
        (5, 5, True, 0, "transient", 77, False),
    ):
        invocation = "isolate_health_runtime old"
        expectation = (
            invocation if should_pass else f"if {invocation}; then exit 98; fi"
        )
        harness = f"""
set -Eeuo pipefail
STOP_RC={stop_rc}
RESET_RC={reset_rc}
FILES_TRUSTED={str(files_trusted).lower()}
RELOAD_RC={reload_rc}
MODE={mode}
SLEEP_RC={sleep_rc}
FILE_CHECKS=0
RUNTIME_CHECKS=0
RELOADED=0
require_runtime_files_for_isolation() {{
    [[ "$1" == old ]]
    FILE_CHECKS=$((FILE_CHECKS + 1))
    [[ "$FILES_TRUSTED" == true ]]
}}
systemctl() {{
    case "$1" in
        stop) return "$STOP_RC" ;;
        reset-failed) return "$RESET_RC" ;;
        daemon-reload)
            (( FILE_CHECKS == 2 )) || return 79
            RELOADED=1
            return "$RELOAD_RC"
            ;;
        *) return 78 ;;
    esac
}}
require_isolated_health_runtime_once() {{
    [[ "$1" == old && "$RELOADED" == 1 ]] || return 1
    RUNTIME_CHECKS=$((RUNTIME_CHECKS + 1))
    case "$MODE:$RUNTIME_CHECKS" in
        loaded:*) return 0 ;;
        transient:1) return 1 ;;
        transient:*) return 0 ;;
        unstable:*) (( RUNTIME_CHECKS % 2 == 0 )) ;;
        *) return 1 ;;
    esac
}}
sleep() {{ return "$SLEEP_RC"; }}
seq() {{ printf '1\\n2\\n3\\n4\\n'; }}
{intent}
{isolate}
{expectation}
if [[ {str(should_pass).lower()} == true ]]; then
    (( FILE_CHECKS == 2 && RELOADED == 1 ))
    if [[ "$MODE" == transient ]]; then
        (( RUNTIME_CHECKS == 3 ))
    else
        (( RUNTIME_CHECKS == 2 ))
    fi
fi
"""
        subprocess.run(["/bin/bash", "-c", harness], check=True)


def assert_consecutive_stability_contract(
    stable: str, stable_name: str, probe_name: str
) -> None:
    harness = f"""
set -Eeuo pipefail
checks=0
{probe_name}() {{ checks=$((checks + 1)); (( checks >= 2 )); }}
sleep() {{ return 0; }}
{stable}
{stable_name}
(( checks == 3 ))
"""
    subprocess.run(["/bin/bash", "-c", harness], check=True)

    negative = f"""
set -Eeuo pipefail
checks=0
{probe_name}() {{ checks=$((checks + 1)); (( checks % 2 == 0 )); }}
sleep() {{ return 0; }}
seq() {{ printf '1\\n2\\n3\\n4\\n'; }}
{stable}
if {stable_name}; then
    exit 99
fi
(( checks >= 4 ))
"""
    subprocess.run(["/bin/bash", "-c", negative], check=True)

    sleep_failure = f"""
set -Eeuo pipefail
{probe_name}() {{ return 0; }}
sleep() {{ return 77; }}
{stable}
if {stable_name}; then
    exit 100
fi
"""
    subprocess.run(["/bin/bash", "-c", sleep_failure], check=True)


def assert_rollback_isolator_negative_path(rollback: str) -> None:
    harness = f"""
set -Eeuo pipefail
exec 3>&1
ROLLBACK_RUNNING=0
PHASE=PREPARED
BACKUP_DIR=/not-used
BACKUP_ROOT=/not-used
TERMINAL_MARKER_COMMITTED=0
done_marker_matches() {{ return 1; }}
sync_path() {{ return 0; }}
require_timer_disabled_link() {{ return 0; }}
sync_timer_enable_state() {{ return 0; }}
isolate_health_runtime() {{ [[ "$1" == known ]]; }}
require_old_runtime_isolated_stable() {{ return 97; }}
systemctl() {{
    printf '%s\\n' "$*" >&3
    if [[ "$1" == is-active ]]; then
        printf '%s\\n' inactive
    fi
    return 0
}}
{rollback}
on_signal() {{
    rollback "$1"
    printf '%s\\n' REENTER_RETURNED >&3
}}
injected=0
set -T
trap 'if [[ "$BASH_COMMAND" == "trap - ERR" && "$injected" == 0 ]]; then injected=1; on_signal 143; fi; :' DEBUG
rollback 7
"""
    result = subprocess.run(
        ["/bin/bash", "-c", harness], capture_output=True, text=True, check=False
    )
    assert result.returncode == 7, result.stderr
    mutations = result.stdout.splitlines()
    assert "REENTER_RETURNED" in mutations, mutations
    assert not any(command.startswith("enable ") for command in mutations), mutations
    assert not any(command.startswith("start ") for command in mutations), mutations


def assert_rollback_immediate_timer_fire_path(rollback: str) -> None:
    harness = f"""
set -Eeuo pipefail
exec 3>&1
ROLLBACK_RUNNING=0
PHASE=PREPARED
BACKUP_DIR=/not-used/transaction
BACKUP_ROOT=/not-used
STATUS_FILE=/not-used/status.json
OLD_SCRIPT_SHA=old-script
OLD_SERVICE_SHA=old-service
OLD_TIMER_SHA=old-timer
FINAL_INVOCATION=
FINAL_STATUS_SHA=
FINAL_STATUS_INODE=
PREPARED_TERMINAL_NAME=
PREPARED_TERMINAL_CONTENT=
TERMINAL_MARKER_COMMITTED=0
timer_started=0
timer_enabled=1
service_busy=0
service_failed=1
done_marker_matches() {{ return 1; }}
sync_path() {{ return 0; }}
require_timer_disabled_link() {{ return 0; }}
require_timer_enabled_link() {{ return 0; }}
sync_timer_enable_state() {{ return 0; }}
isolate_health_runtime() {{
    [[ "$1" == known ]] || return 68
    service_failed=0
    printf '%s\n' ISOLATE >&3
    return 0
}}
require_old_runtime_isolated_stable() {{ (( service_busy == 0 && service_failed == 0 )); }}
require_old_runtime_enabled_inactive() {{ (( service_busy == 0 && service_failed == 0 )); }}
require_old_runtime_active() {{
    if (( service_busy == 1 )); then
        printf '%s\\n' OLD_ACTIVE_BUSY >&3
        return 66
    fi
    (( service_failed == 1 )) || return 67
    return 0
}}
prepare_terminal_marker() {{ TERMINAL_MARKER_COMMITTED=0; return 0; }}
settle_timer_schedule() {{
    service_busy=0
    service_failed=1
    SETTLED_INVOCATION=settled-invocation
    SETTLED_TIMER_TRIGGER=4242
    return 0
}}
wait_health_idle() {{
    service_busy=0
    if (( timer_started == 1 )); then
        service_failed=1
    fi
    return 0
}}
require_status() {{ return 0; }}
sha() {{ printf '%s\\n' status-sha; }}
stat() {{ printf '%s\\n' 99; }}
persist_status_snapshot() {{ return 0; }}
validate_timer_quiescent() {{ return 0; }}
commit_terminal_marker() {{
    TERMINAL_MARKER_COMMITTED=1
    printf '%s\\n' COMMIT >&3
    return 0
}}
marker_matches() {{ return 0; }}
systemctl() {{
    printf '%s\\n' "$*" >&3
    case "$1" in
        disable) timer_enabled=0; timer_started=0; service_busy=0 ;;
        enable) timer_enabled=1 ;;
        reset-failed) service_failed=0 ;;
        start)
            if [[ "$2" == shuzijun-internal-health.timer ]]; then
                timer_started=1
                service_busy=1
                service_failed=0
            elif [[ "$2" == shuzijun-internal-health.service ]]; then
                service_busy=1
                service_failed=1
            fi
            ;;
        stop) service_busy=0 ;;
        is-enabled)
            (( timer_enabled == 1 )) && printf '%s\\n' enabled || printf '%s\\n' disabled
            ;;
        is-active)
            if [[ "$2" == shuzijun-internal-health.timer ]]; then
                (( timer_started == 1 )) && printf '%s\\n' active || printf '%s\\n' inactive
            else
                if (( service_busy == 1 )); then
                    printf '%s\\n' activating
                elif (( service_failed == 1 )); then
                    printf '%s\\n' failed
                else
                    printf '%s\\n' inactive
                fi
            fi
            ;;
    esac
    return 0
}}
{rollback}
rollback 7
"""
    result = subprocess.run(
        ["/bin/bash", "-c", harness], capture_output=True, text=True, check=False
    )
    assert result.returncode == 7, result.stderr
    events = result.stdout.splitlines()
    assert "COMMIT" in events, events
    assert "OLD_ACTIVE_BUSY" not in events, events
    assert sum(event.startswith("disable --now") for event in events) == 1, events
    assert events.count("ISOLATE") == 1, events
    assert sum(event.startswith("reset-failed shuzijun-internal-health.service") for event in events) == 1, events
    assert sum(event.startswith("start shuzijun-internal-health.service") for event in events) == 1, events


def main() -> None:
    deployer_bytes = DEPLOYER.read_bytes()
    text = deployer_bytes.decode("utf-8")
    lines = text.splitlines()
    release = RELEASE.read_text(encoding="utf-8")
    health_script_sha256 = hashlib.sha256(HEALTH_SCRIPT.read_bytes()).hexdigest()
    health_service_text = HEALTH_SERVICE.read_text(encoding="utf-8")
    health_service_sha256 = hashlib.sha256(HEALTH_SERVICE.read_bytes()).hexdigest()
    health_timer_sha256 = hashlib.sha256(HEALTH_TIMER.read_bytes()).hexdigest()
    private_log_config_sha256 = hashlib.sha256(PRIVATE_LOG_CONFIG.read_bytes()).hexdigest()
    snapshot_cron_sha256 = hashlib.sha256(SNAPSHOT_CRON.read_bytes()).hexdigest()
    deployer_sha256 = hashlib.sha256(deployer_bytes).hexdigest()
    deployer_contract_sha256 = hashlib.sha256(DEPLOYER_CONTRACT.read_bytes()).hexdigest()
    internal_health_test_sha256 = hashlib.sha256(
        INTERNAL_HEALTH_TEST.read_bytes()
    ).hexdigest()

    subprocess.run(["/bin/bash", "-n", str(DEPLOYER)], check=True)
    assert lines[:4] == [
        "#!/bin/bash",
        "set -Eeuo pipefail",
        "IFS=$'\\n\\t'",
        "umask 077",
    ]
    assert "PATH=/usr/sbin:/usr/bin:/sbin:/bin" in lines
    assert "unset CDPATH ENV BASH_ENV PYTHONPATH PYTHONHOME || true" in lines
    assert "ExecStart=/usr/bin/python3 -I /usr/local/sbin/shuzijun-internal-health" in health_service_text
    assert "SuccessExitStatus=2" in health_service_text

    for fixed_value in (
        "RELEASE_ID=build42.10",
        "DEPLOYER_PATH=/run/deploy-shuzijun-health-build42.10",
        "STAGE=/run/shuzijun-health-build42.10-$NODE",
        "SCRIPT_TARGET=/usr/local/sbin/shuzijun-internal-health",
        "SERVICE_TARGET=/etc/systemd/system/shuzijun-internal-health.service",
        "TIMER_TARGET=/etc/systemd/system/shuzijun-internal-health.timer",
        "WANTS_DIR=/etc/systemd/system/timers.target.wants",
        "WANTS_LINK=$WANTS_DIR/shuzijun-internal-health.timer",
        "SERVICE_OBJECT_PATH=/org/freedesktop/systemd1/unit/shuzijun_2dinternal_2dhealth_2eservice",
        "TIMER_OBJECT_PATH=/org/freedesktop/systemd1/unit/shuzijun_2dinternal_2dhealth_2etimer",
        "STATUS_FILE=$STATUS_DIR/status.json",
        "BACKUP_ROOT=/var/backups/shuzijun-health-monitor",
        "LOCK_DIR=/run/shuzijun-health-monitor-install",
        "ROLE_VERIFY_SHA=5fe67111642c53895e16afd0a9d6a341af881c3711736f9fe40a34b830e20a58",
        "PRIVATE_LOG_CONFIG_TARGET=/etc/tmpfiles.d/shuzijun-private-logs.conf",
        "SNAPSHOT_CRON_TARGET=/etc/cron.d/tencent-daily-snapshot",
        "SNAPSHOT_EXECUTION_LOCK=/run/tencent-snapshot.lock",
        "PRIVATE_LOG_DIR=/var/lib/shuzijun-logs",
        "NEW_SCRIPT_SHA=bd1f78f323346c04ed8b9e7a032baa1b11a6517cccfa4078e6914bd5d4c01cfe",
        "NEW_SERVICE_SHA=ebd20b9de5e145cec7f2a2ef3a036202449187f69686aad2dd5a3ca6202b765b",
        "NEW_TIMER_SHA=c7e1137ffd0df3fb8a37df08bfe4876b33ec4d92078e9ea4b94ec646a4a9ce3e",
        "NEW_PRIVATE_LOG_CONFIG_SHA=ba11676ee8c5d65faf72ae63bf7d80247860c73f33532e07e11371faff6c6f9f",
        "NEW_SNAPSHOT_CRON_SHA=3b9cd2994249180176c9220f617fc8ccf3f782322fd63943f0a3fddbd290ffe3",
        "OLD_SCRIPT_SHA=34961aa2c05d8c326c5a244a373dd5fadbaf89c4bfffab0898d8f379bd50d0a1",
        "OLD_SERVICE_SHA=ebd20b9de5e145cec7f2a2ef3a036202449187f69686aad2dd5a3ca6202b765b",
        "OLD_TIMER_SHA=c7e1137ffd0df3fb8a37df08bfe4876b33ec4d92078e9ea4b94ec646a4a9ce3e",
        "APP_MANIFEST_SHA=b15fab2426d7fb7e11e40361c8a22933b5950e6e2e05406a576924cd9a56b9d1",
        "APP_PLUGIN_SHA=92a9eecc72a4b0b70475d2ea2c6fe27be682965211a14c471cf0cc5f6f75ac8f",
    ):
        assert fixed_value in lines, fixed_value
    assert f"NEW_SCRIPT_SHA={health_script_sha256}" in lines
    assert f"NEW_SERVICE_SHA={health_service_sha256}" in lines
    assert f"NEW_TIMER_SHA={health_timer_sha256}" in lines
    assert f"NEW_PRIVATE_LOG_CONFIG_SHA={private_log_config_sha256}" in lines
    assert f"NEW_SNAPSHOT_CRON_SHA={snapshot_cron_sha256}" in lines
    assert RELEASE == Path("Server/releases/v1.3.30-build42.14.md")
    assert "Build 42.14" in release
    for release_value in (
        f"HEALTH_DEPLOYER_SHA256={deployer_sha256}",
        f"HEALTH_DEPLOYER_CONTRACT_SHA256={deployer_contract_sha256}",
        f"HEALTH_RUNTIME_SHA256={health_script_sha256}",
        f"HEALTH_RUNTIME_CONTRACT_SHA256={internal_health_test_sha256}",
        f"HEALTH_SERVICE_SHA256={health_service_sha256}",
        f"HEALTH_TIMER_SHA256={health_timer_sha256}",
        f"PRIVATE_LOG_CONFIG_SHA256={private_log_config_sha256}",
        f"SNAPSHOT_CRON_SHA256={snapshot_cron_sha256}",
        "APP_MANIFEST_SHA256=b15fab2426d7fb7e11e40361c8a22933b5950e6e2e05406a576924cd9a56b9d1",
        "APP_PLUGIN_ENTRY_SHA256=92a9eecc72a4b0b70475d2ea2c6fe27be682965211a14c471cf0cc5f6f75ac8f",
        "OLD_HEALTH_RUNTIME_SHA256=34961aa2c05d8c326c5a244a373dd5fadbaf89c4bfffab0898d8f379bd50d0a1",
        "OLD_HEALTH_SERVICE_SHA256=ebd20b9de5e145cec7f2a2ef3a036202449187f69686aad2dd5a3ca6202b765b",
        "OLD_HEALTH_TIMER_SHA256=c7e1137ffd0df3fb8a37df08bfe4876b33ec4d92078e9ea4b94ec646a4a9ce3e",
    ):
        assert release_value in release, release_value
    assert "DOC_COMMIT" not in text
    assert "SHORT_COMMIT" not in text
    assert "build41.12" not in text
    assert "build41.11" not in text
    assert "build41.10" not in text
    assert "build41.9" not in text
    assert "build41.8" not in text
    assert "build41.7" not in text
    assert "build42.5" not in text
    assert "76f1591503d2bb11005d50f0429171b638caac40246be10ab260c500a63cabe9" not in text
    assert "90d50b197ad39e2efb45d2e394f6926c0c1f01d501ef95e4a21de18bd8581fa3" not in text
    assert "tmp=$parent/.$base.build42.10.$$" in text
    assert "BACKUP_DIR=$BACKUP_ROOT/$STAMP-$NODE-build42.10" in lines
    assert "[[ $# -eq 2 ]]" in text
    assert '[[ "$0" == "$DEPLOYER_PATH" ]]' in text

    self_hash_start = line_number(lines, "DEPLOYER_SHA=$(")
    lock_open = line_number(lines, 'exec 9>>"$LOCK_FILE"')
    assert self_hash_start < lock_open
    for guard in (
        "O_NOFOLLOW",
        "before_path.st_dev, before_path.st_ino",
        "before_fd.st_dev, before_fd.st_ino",
        "(0, 0, 0o700, 1)",
        "deployer changed while hashing",
        "deployer path changed while hashing",
        "deployer_sha=$DEPLOYER_SHA",
    ):
        assert guard in text, guard

    frozen = function_body(lines, "require_frozen_files", "require_old_state")
    for parent in (
        "/usr",
        "/usr/local",
        "/usr/local/sbin",
        "/etc",
        "/etc/systemd",
        "/etc/systemd/system",
    ):
        assert f"require_safe_parent {parent} || return 1" in frozen
    assert "(( (8#$RUN_MODE & 0022) == 0 ))" in text
    assert "stat -c '%F" not in text
    assert "regular file:0:0" not in text
    assert "symbolic link:0:0" not in text
    lock_prelude = "\n".join(lines[: line_number(lines, 'flock -n 9') + 1])
    assert 'if [[ -e "$LOCK_FILE" || -L "$LOCK_FILE" ]]' in lock_prelude
    assert lock_prelude.count('[[ ! -L "$LOCK_FILE" && -f "$LOCK_FILE" ]]') == 2
    assert lock_prelude.count('[[ "$(realpath -e -- "$LOCK_FILE")" == "$LOCK_FILE" ]]') == 2
    assert lock_prelude.count("stat -c '%u:%g:%a:%h' -- \"$LOCK_FILE\"") == 2
    assert "stat -c '%F:%u:%g:%a:%h' \"$LOCK_FILE\"" not in lock_prelude
    assert lock_prelude.count("'0:0:600:1'") == 2
    assert "flock -n 9" in text

    snapshot_lock_file = function_body(
        lines,
        "require_snapshot_execution_lock_file",
        "acquire_snapshot_execution_lock",
    )
    assert "stat -c '%u:%g:%a:%h'" in snapshot_lock_file
    assert '[[ "$metadata" == 0:0:*:1 ]]' in snapshot_lock_file
    snapshot_lock_start = line_number(lines, "acquire_snapshot_execution_lock() {")
    snapshot_lock_end = line_number(lines, "# Hold the same lock", snapshot_lock_start)
    snapshot_lock = "\n".join(lines[snapshot_lock_start:snapshot_lock_end])
    snapshot_lock_call = line_number(
        lines, "acquire_snapshot_execution_lock", snapshot_lock_end
    )
    install_lock_mutation = line_number(lines, 'if [[ -e "$LOCK_DIR"', snapshot_lock_call)
    assert snapshot_lock_call < install_lock_mutation
    for guard in (
        'exec 8>>"$SNAPSHOT_EXECUTION_LOCK"',
        "/usr/bin/flock -n 8",
        "snapshot execution lock busy",
        'stat -Lc \'%d:%i\' -- "/proc/$ROOT_BASHPID/fd/8"',
        '[[ "$path_identity" == "$descriptor_identity" ]]',
    ):
        assert guard in snapshot_lock, guard
    snapshot_lock_lines = snapshot_lock.splitlines()
    snapshot_flock = line_number(snapshot_lock_lines, "/usr/bin/flock -n 8")
    snapshot_first_metadata_write = line_number(
        snapshot_lock_lines, 'chown root:root "$SNAPSHOT_EXECUTION_LOCK"'
    )
    assert snapshot_flock < snapshot_first_metadata_write
    assert text.count("/usr/bin/flock -n 8") == 1
    assert "flock -u 8" not in text and "exec 8>&-" not in text
    assert_snapshot_lock_busy_zero_mutation(snapshot_lock)

    require_status = function_body(lines, "require_status", "unit_value")
    for guard in (
        'require_dir "$STATUS_DIR" 700 || return 1',
        "require_safe_parent /var || return 1",
        "require_safe_parent /var/lib || return 1",
    ):
        assert guard in require_status
    assert_status_boundary_negative_path(require_status)

    enabled_link = function_body(
        lines, "require_timer_enabled_link", "require_timer_disabled_link"
    )
    disabled_link = function_body(
        lines, "require_timer_disabled_link", "sync_timer_enable_state"
    )
    enable_sync = function_body(lines, "sync_timer_enable_state", "unit_value")
    assert "0:0:777:1" in enabled_link
    assert '[[ "$target" == "$TIMER_TARGET" ]] || return 1' in enabled_link
    assert '[[ "$(realpath -e -- "$WANTS_LINK")" == "$TIMER_TARGET" ]]' in enabled_link
    assert '[[ ! -e "$WANTS_DIR" && ! -L "$WANTS_DIR" ]]' in disabled_link
    assert "require_safe_parent /etc/systemd/system || return 1" in disabled_link
    assert '[[ ! -e "$WANTS_LINK" && ! -L "$WANTS_LINK" ]] || return 1' in disabled_link
    assert 'if [[ -e "$WANTS_DIR" || -L "$WANTS_DIR" ]]' in enable_sync
    assert 'sync_path "$WANTS_DIR" || return 1' in enable_sync
    assert "sync_path /etc/systemd/system || return 1" in enable_sync

    exec_json = function_body(lines, "exec_start_ex_json", "require_exact_exec_start")
    exact_exec = function_body(
        lines, "require_exact_exec_start", "require_service_execution_context"
    )
    service_context = function_body(
        lines, "require_service_execution_context", "unit_uint64"
    )
    assert "/usr/bin/busctl --json=short --system get-property" in exec_json
    assert "org.freedesktop.systemd1.Service ExecStartEx" in exec_json
    assert 'output=$(exec_start_ex_json "$object") || return 1' in exact_exec
    assert 'payload["type"] != "a(sasasttttuii)"' in exact_exec
    assert "entry[0] != expected_path" in exact_exec
    assert "entry[1] != expected_argv" in exact_exec
    assert "entry[2] != []" in exact_exec
    for property_name in (
        "User",
        "Group",
        "Environment",
        "EnvironmentFiles",
        "PassEnvironment",
        "UnsetEnvironment",
        "WorkingDirectory",
        "RootDirectory",
        "RootImage",
        "ExecSearchPath",
    ):
        assert f'unit_value "$unit" {property_name}) || return 1' in service_context
    assert_exact_exec_start_contract(exact_exec)
    assert_service_execution_context_negative_paths(service_context)

    old_state = function_body(lines, "require_old_state", "require_old_runtime_loaded")
    old_loaded = function_body(
        lines, "require_old_runtime_loaded", "require_old_runtime_isolated"
    )
    old_isolated = function_body(
        lines, "require_old_runtime_isolated", "require_old_runtime_isolated_stable"
    )
    old_isolated_stable = function_body(
        lines,
        "require_old_runtime_isolated_stable",
        "require_old_runtime_enabled_inactive",
    )
    old_active = function_body(lines, "require_old_runtime_active", "require_stage")
    new_units = function_body(
        lines, "require_new_units_once", "require_new_units_stable"
    )
    new_units_stable = function_body(
        lines, "require_new_units_stable", "marker_matches"
    )
    assert "require_old_runtime_loaded active inactive-or-failed preflight || return 1" in old_state
    for body in (old_loaded, new_units):
        assert "service_dropins=$(unit_value" in body
        assert "timer_dropins=$(unit_value" in body
        assert '[[ -z "$service_dropins" && -z "$timer_dropins" ]] || return 1' in body
        assert '-z "$(unit_value' not in body
    for guard in (
        "require_frozen_files || return 1",
        'require_file "$ROLE_VERIFY" 755 "$ROLE_VERIFY_SHA" || return 1',
        '/usr/bin/python3 -I "$ROLE_VERIFY" "$ROLE" || return 1',
        "timer_state=$(unit_value shuzijun-internal-health.timer ActiveState) || return 1",
        "service_state=$(unit_value shuzijun-internal-health.service ActiveState) || return 1",
        "FragmentPath",
        "DropInPaths",
        "ExecStart",
        "ExecCondition",
        "ExecStartPre",
        "ExecStartPost",
        "ExecReload",
        "ExecStop",
        "ExecStopPost",
        "SuccessExitStatus",
        "NeedDaemonReload",
        "Type",
        "timer_unit=$(unit_value shuzijun-internal-health.timer Unit) || return 1",
        "service_job=$(unit_value shuzijun-internal-health.service Job) || return 1",
        "timer_job=$(unit_value shuzijun-internal-health.timer Job) || return 1",
        'systemd-analyze verify "$SERVICE_TARGET" "$TIMER_TARGET" || return 1',
    ):
        assert guard in old_loaded, guard
    assert '[[ "$expected_service_state" == inactive || "$expected_service_state" == inactive-or-failed ]] || return 1' in old_loaded
    assert '[[ "$timer_policy" == strict || "$timer_policy" == preflight ]] || return 1' in old_loaded
    assert '[[ "$timer_substate" == waiting || "$timer_substate" == elapsed ]] || return 1' in old_loaded
    assert "inactive:dead" in old_loaded and "failed:failed" in old_loaded
    assert '[[ "$service_result" == exit-code && "$service_main_status" == 1 ]] || return 1' in old_loaded
    assert '[[ "$success_status" == 2 ]] || return 1' in old_loaded
    assert 'require_exact_exec_start "$SERVICE_OBJECT_PATH" /usr/bin/python3 /usr/bin/python3 -I /usr/local/sbin/shuzijun-internal-health || return 1' in old_loaded
    assert "require_service_execution_context shuzijun-internal-health.service || return 1" in old_loaded
    assert 'require_exact_exec_start "$SERVICE_OBJECT_PATH" /usr/bin/python3 /usr/bin/python3 -I /usr/local/sbin/shuzijun-internal-health || return 1' in new_units
    assert "require_service_execution_context shuzijun-internal-health.service || return 1" in new_units
    assert_old_loaded_definition_negative_paths(old_loaded)
    for guard in (
        "require_old_runtime_loaded inactive inactive || return 1",
        'systemctl is-enabled shuzijun-internal-health.timer',
        "require_timer_disabled_link || return 1",
    ):
        assert guard in old_isolated, guard
    assert "require_old_runtime_loaded active inactive-or-failed || return 1" in old_active

    # Raw D-Bus uint64 values avoid systemctl's humanized duration output.
    uint64 = function_body(lines, "unit_uint64", "service_usec")
    assert "/usr/bin/busctl --system get-property" in uint64
    assert '[[ "$signature" == t && "$value" =~ ^[0-9]+$' in uint64
    for line in lines:
        if "USec" in line and "unit_value" in line:
            raise AssertionError(f"humanized systemctl time used: {line}")

    backup = function_body(lines, "backup_one", "atomic_install")
    assert "local source=$1 name=$2 expected_sha=$3 mode=$4 copy" in backup
    assert 'cp -a --reflink=never -- "$source" "$copy" || return 1' in backup
    assert 'require_file "$copy" "$mode" "$expected_sha" || return 1' in backup
    assert 'require_file "$source" "$mode" "$expected_sha" || return 1' in backup
    for call in (
        'backup_one "$SCRIPT_TARGET" script.old "$OLD_SCRIPT_SHA" 700',
        'backup_one "$SERVICE_TARGET" service.old "$OLD_SERVICE_SHA" 644',
        'backup_one "$TIMER_TARGET" timer.old "$OLD_TIMER_SHA" 644',
        'backup_one "$STATUS_FILE" status.old "$OLD_STATUS_SHA" 600',
    ):
        assert call in text
    for transactional_evidence in (
        'capture_root_crontab "$BACKUP_DIR/root-crontab.old"',
        "ROOT_CRONTAB_STATE=$CAPTURED_CRONTAB_STATE",
        "ROOT_CRONTAB_SHA=$CAPTURED_CRONTAB_SHA",
        'record_optional_asset "$PRIVATE_LOG_CONFIG_TARGET" private-logs-conf.old',
        'record_optional_asset "$SNAPSHOT_CRON_TARGET" snapshot-cron.old',
        "record_private_log_state",
        '"$BACKUP_DIR/root-crontab.old"',
        '"$BACKUP_DIR/root-crontab.migrated"',
    ):
        assert transactional_evidence in text
    assert 'backup_one "$AUTHORITY_LOG"' not in text
    assert 'backup_one "$STANDBY_LOG"' not in text
    assert 'backup_one "$SNAPSHOT_LOG"' not in text
    backup_end = line_number(lines, 'backup_one "$STATUS_FILE"')
    assert line_number(lines, "require_frozen_files", backup_end) > backup_end
    assert line_number(lines, 'require_file "$STATUS_FILE" 600 "$OLD_STATUS_SHA"', backup_end) > backup_end

    write_marker = function_body(lines, "write_marker", "backup_one")
    for operation in (
        "printf '%s\\n'",
        "chown root:root",
        "chmod 600",
        "sync_path",
        "mv -T",
    ):
        matching = [line for line in write_marker.splitlines() if operation in line]
        assert matching and all("|| return 1" in line for line in matching), operation
    assert "PREPARED|COMMITTED|STATUS_MAY_CHANGE|ACCEPTED" in write_marker
    assert "DONE" not in write_marker and "ROLLED_BACK" not in write_marker

    prepare_terminal = function_body(
        lines, "prepare_terminal_marker", "commit_terminal_marker"
    )
    commit_terminal = function_body(
        lines, "commit_terminal_marker", "done_marker_matches"
    )
    assert "mv -T" not in prepare_terminal
    assert 'sync_path "$tmp_path" || return 1' in prepare_terminal
    assert 'sync_path "$BACKUP_DIR" || return 1' in prepare_terminal
    assert 'marker_matches "$PREPARED_TERMINAL_NAME" "$PREPARED_TERMINAL_CONTENT" || return 1' in prepare_terminal
    commit_lines = commit_terminal.splitlines()
    terminal_rename = line_number(commit_lines, "mv -T --")
    terminal_published = line_number(commit_lines, "TERMINAL_MARKER_COMMITTED=1")
    terminal_first_sync = line_number(commit_lines, 'sync_path "$final_path"')
    assert terminal_rename < terminal_published < terminal_first_sync

    assert PRIVATE_LOG_CONFIG.read_text(encoding="utf-8").splitlines() == [
        "d /var/lib/shuzijun-logs 0700 root root -",
        "f /var/lib/shuzijun-logs/sync-authority.log 0600 root root -",
        "f /var/lib/shuzijun-logs/sync-standby.log 0600 root root -",
        "f /var/lib/shuzijun-logs/snapshot.log 0600 root root -",
    ]
    assert SNAPSHOT_CRON.read_text(encoding="utf-8").splitlines() == [
        "SHELL=/bin/bash",
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "CRON_TZ=Asia/Shanghai",
        "31 3 * * * root umask 077; flock -xn /run/tencent-snapshot.lock -c /usr/local/sbin/tencent-daily-snapshot >>/var/lib/shuzijun-logs/snapshot.log 2>&1",
    ]
    assert stat.S_IMODE(PRIVATE_LOG_CONFIG.stat().st_mode) == 0o644
    assert stat.S_IMODE(SNAPSHOT_CRON.stat().st_mode) == 0o644
    assert text.count("/var/log/tencent-snapshot.log") == 1
    assert "/var/log/wp-sync.log" not in text
    assert "/var/log/shuzijun-sync-receiver.log" not in text

    private_file = function_body(
        lines, "require_private_log_file", "require_private_logs"
    )
    private_logs = function_body(
        lines, "require_private_logs", "record_private_log_state"
    )
    restore_private_logs = function_body(
        lines, "restore_private_log_state", "wait_health_idle"
    )
    capture_crontab = function_body(
        lines, "capture_root_crontab", "transform_root_crontab"
    )
    transform_crontab = function_body(
        lines, "transform_root_crontab", "require_snapshot_migration_source"
    )
    snapshot_migration_source = function_body(
        lines, "require_snapshot_migration_source", "snapshot_producer_count"
    )
    producer_inventory = function_body(
        lines, "snapshot_producer_count", "require_snapshot_producer_count"
    )
    for guard in (
        "0:0:600:1",
        "realpath -e",
        "! -L",
    ):
        assert guard in private_file
    for guard in ("require_safe_parent /", "require_dir \"$PRIVATE_LOG_DIR\" 700"):
        assert guard in private_logs
    assert_snapshot_lock_cross_window_rollback(snapshot_lock, restore_private_logs)
    for guard in (
        "/usr/bin/crontab -l",
        "no crontab for root",
        "CAPTURED_CRONTAB_STATE",
        "CAPTURED_CRONTAB_SHA",
        "require_file \"$destination\" 600",
    ):
        assert guard in capture_crontab
    assert "content == expected" in transform_crontab
    assert "removed not in (0, 1)" in transform_crontab
    assert_crontab_transform_contract(transform_crontab)
    assert_snapshot_migration_source_contract(snapshot_migration_source)
    assert '[[ "$REMOVED_SNAPSHOT_LINES" == 1 ]]' not in text
    for guard in (
        "O_NOFOLLOW",
        "O_NONBLOCK",
        "st_nlink != 1",
        "st_mtime_ns",
        "st_ctime_ns",
        "not stripped.startswith(b\"#\")",
    ):
        assert guard in producer_inventory
    assert "/usr/bin/systemd-tmpfiles --create \"$PRIVATE_LOG_CONFIG_TARGET\"" in text
    assert 'require_snapshot_producer_count "$BACKUP_DIR/root-crontab.old" 1' in text
    assert 'require_snapshot_producer_count "$verification" 1' in text
    assert "stargate_digest" not in text
    assert "OLD_STARGATE_SHA" not in text
    install_crontab = function_body(
        lines, "install_migrated_root_crontab", "restore_root_crontab"
    )
    restore_crontab = function_body(
        lines, "restore_root_crontab", "restore_private_log_state"
    )
    assert "sync || return 1" in install_crontab
    assert "sync || return 1" in restore_crontab
    assert '[[ "$CAPTURED_CRONTAB_SHA" == "$TRANSFORMED_CRONTAB_SHA" ]]' in install_crontab
    assert '[[ "$CAPTURED_CRONTAB_SHA" == "$ROOT_CRONTAB_SHA" ]]' in restore_crontab
    verify_snapshot = function_body(
        lines, "verify_current_snapshot_state", "require_new_support_assets"
    )
    assert '[[ "$CAPTURED_CRONTAB_STATE" == "$EXPECTED_CRONTAB_STATE" ]]' in verify_snapshot
    assert '[[ "$CAPTURED_CRONTAB_SHA" == "$TRANSFORMED_CRONTAB_SHA" ]]' in verify_snapshot
    assert '[[ $- == *e* ]] && errexit_was_set=1' in capture_crontab
    assert "if (( errexit_was_set == 1 )); then" in capture_crontab

    validate_status = function_body(lines, "validate_status", "validate_last_invocation")
    for allowed_reason in (
        "authority_sync_generation_missing_or_invalid",
        "authority_sync_generation_behind_completed_log",
        "authority_forbidden_failover_timer_active",
        "sync_timer_missing_or_disabled",
        "sync_service_result_not_success",
        "standby_failover_timer_disabled",
        "standby_failover_service_result_not_success",
        "standby_forbidden_sync_timer_active",
        "standby_forbidden_cdn_timer_active",
        "standby_failover_mode_not_primary",
        "standby_failover_state_unhealthy_or_stale",
        "standby_sync_generation_missing_or_invalid",
        "standby_sync_commit_generation_missing_or_invalid",
        "standby_sync_generation_mismatch_applied_log",
        "standby_sync_generation_mismatch_commit",
        "snapshot_last_success_untrusted_or_stale",
        "sync_last_success_untrusted_or_stale",
        "sync_log_generation_missing_or_invalid",
    ):
        assert f'"{allowed_reason}"' in validate_status
    for validation_guard in (
        'payload.get("critical_reasons") != []',
        "reasons != sorted(set(reasons))",
        "not set(reasons) <= allowed_reasons[role]",
        'expected_status = "degraded" if reasons else "healthy"',
        "expected_status_exit = 2 if reasons else 0",
        "expected_exit != expected_status_exit",
        'summary.get("present") is not True',
        'summary.get("trusted") is not True',
        'summary.get("parent_trusted") is not True',
        'operations.get("accepted_generation")',
        'operations.get("committed_generation")',
        "accepted.get(\"value\") != committed.get(\"value\")",
        'not 0 <= accepted.get("value") < 2**63',
        'not 0 <= committed.get("value") < 2**63',
        "actual_generation_reasons != expected_generation_reasons",
    ):
        assert validation_guard in validate_status
    assert 'payload.get("schema") != 3' in validate_status

    idle = function_body(
        lines, "wait_health_idle", "require_runtime_files_for_isolation"
    )
    assert idle.count("ActiveState") >= 2
    assert idle.count("Job") >= 2
    assert "state_again" in idle and "job_again" in idle
    runtime_files = function_body(
        lines,
        "require_runtime_files_for_isolation",
        "require_isolated_health_runtime_once",
    )
    isolated_once = function_body(
        lines, "require_isolated_health_runtime_once", "run_systemctl_unit_intent"
    )
    systemctl_intent = function_body(
        lines, "run_systemctl_unit_intent", "isolate_health_runtime"
    )
    isolate_runtime = function_body(
        lines, "isolate_health_runtime", "require_old_state_stable"
    )
    assert 'require_frozen_files || return 1' in runtime_files
    for target, mode, old_sha, new_sha in (
        ("$SCRIPT_TARGET", "700", "$OLD_SCRIPT_SHA", "$NEW_SCRIPT_SHA"),
        ("$SERVICE_TARGET", "644", "$OLD_SERVICE_SHA", "$NEW_SERVICE_SHA"),
        ("$TIMER_TARGET", "644", "$OLD_TIMER_SHA", "$NEW_TIMER_SHA"),
    ):
        assert (
            f'require_known_file "{target}" {mode} "{old_sha}" "{new_sha}"'
            in runtime_files
        )
    for guard in (
        '[[ "$timer_load" == loaded && "$service_load" == loaded ]]',
        '[[ "$timer_state" == inactive && "$timer_substate" == dead && -z "$timer_job" ]]',
        '[[ "$service_state" == inactive && "$service_substate" == dead && -z "$service_job" ]]',
        '[[ "$timer_unit" == shuzijun-internal-health.service && "$timer_reload" == no ]]',
        '[[ "$service_reload" == no && "$service_type" == oneshot ]]',
    ):
        assert guard in isolated_once, guard
    assert_systemctl_unit_intent_contract(systemctl_intent)
    assert_isolate_health_runtime_contract(isolate_runtime, systemctl_intent)
    assert_consecutive_stability_contract(
        old_isolated_stable,
        "require_old_runtime_isolated_stable",
        "require_old_runtime_isolated",
    )
    assert_consecutive_stability_contract(
        new_units_stable, "require_new_units_stable", "require_new_units_once"
    )
    stable_old_state = function_body(
        lines, "require_old_state_stable", "validate_timer_quiescent"
    )
    assert "for attempt in $(seq 1 40)" in stable_old_state
    assert stable_old_state.count("if require_old_state; then") == 2
    assert "wait_health_idle || return 1" in stable_old_state
    assert_old_state_stability_retry(stable_old_state)
    timer_validation = function_body(lines, "validate_timer_quiescent", "settle_timer_schedule")
    assert "for attempt in 1 2" in timer_validation
    assert "Job" in timer_validation
    assert "next_elapse > now_usec + minimum_future_usec" in timer_validation
    assert "next_elapse <= now_usec + maximum_future_usec" in timer_validation
    assert '[[ "$now_ns" =~ ^[0-9]+$ && "$now_mono" =~ ^[0-9]+$ ]] || return 1' in timer_validation
    settle = function_body(lines, "settle_timer_schedule", "clock_pair")
    assert "seq 1 1400" in settle
    assert "wait_health_idle || return 1" in settle
    assert 'validate_timer_quiescent "$invocation" "$trigger" 60000000 360000000' in settle
    assert "SETTLED_INVOCATION=$invocation" in settle
    timer_start_helper = function_body(
        lines, "start_disabled_timer_and_settle", "classify_timer_activation_evidence"
    )
    assert "systemctl start shuzijun-internal-health.timer || return 1" in timer_start_helper
    assert "settle_timer_schedule || return 1" in timer_start_helper
    assert "NextElapseUSecMonotonic" not in timer_start_helper
    assert_main_immediate_timer_fire_path(timer_start_helper)
    timer_evidence = function_body(
        lines, "classify_timer_activation_evidence", "validate_status"
    )
    assert "TIMER_ACTIVATION_EVIDENCE=unchanged" in timer_evidence
    assert "TIMER_ACTIVATION_EVIDENCE=invoked" in timer_evidence
    assert_timer_activation_evidence_contract(timer_evidence)
    assert re.search(r"LastTriggerUSec(?!Monotonic)", text) is None

    validator = function_body(
        lines, "validate_last_invocation", "require_new_units_once"
    )
    assert "outer_start_mono=$6 outer_end_mono=$7" in validator
    assert "service_usec ExecMainStartTimestamp" in validator
    assert "service_usec ExecMainExitTimestampMonotonic" in validator
    assert "start_wall * 1000 >= start_ns" in validator
    assert "exit_mono * 1000 <= outer_end_mono" in validator
    assert 'validate_status "$previous_inode" "$previous_sha" "$((start_wall * 1000))" "$((exit_wall * 1000))" "$main_status"' in validator
    assert '( "$main_status" == 0 || "$main_status" == 2 )' in validator
    assert "VALIDATED_INVOCATION=$invocation" in validator
    assert "VALIDATED_EXIT_STATUS=$main_status" in validator
    assert validator.count("|| return 1") >= 18
    assert_validator_negative_path(validator)
    assert_validator_exit_status_contract(validator)
    assert re.search(r"validate_last_invocation[^\n]*\|", text) is None
    assert "$(validate_last_invocation" not in text

    rollback = function_body(lines, "rollback", "on_error")
    marker = function_body(lines, "marker_matches", "done_marker_matches")
    for guard in (
        "O_NOFOLLOW",
        "(0, 0, 0o600, 1)",
        "data != expected",
        "before_path.st_dev, before_path.st_ino",
        "after_path.st_dev, after_path.st_ino",
    ):
        assert guard in marker
    assert "if done_marker_matches || {" in rollback
    assert "TERMINAL_MARKER_COMMITTED == 1" in rollback
    assert '.terminal-DONE-$$' in rollback
    assert rollback.index("if done_marker_matches") < rollback.index(
        "systemctl disable --now"
    )
    assert "no rollback was performed" in rollback
    isolate = line_number(rollback.splitlines(), "systemctl disable --now")
    rollback_isolate = line_number(
        rollback.splitlines(), "isolate_health_runtime known", isolate
    )
    isolation_gate = line_number(rollback.splitlines(), "if (( isolation_ok == 1 ))")
    root_crontab_restore = line_number(
        rollback.splitlines(), "restore_root_crontab", isolation_gate
    )
    snapshot_cron_restore = line_number(
        rollback.splitlines(),
        'restore_optional_asset "$SNAPSHOT_CRON_TARGET"',
        root_crontab_restore,
    )
    private_config_restore = line_number(
        rollback.splitlines(),
        'restore_optional_asset "$PRIVATE_LOG_CONFIG_TARGET"',
        snapshot_cron_restore,
    )
    private_log_restore = line_number(
        rollback.splitlines(), "restore_private_log_state", private_config_restore
    )
    first_restore = line_number(rollback.splitlines(), "atomic_restore")
    assert (
        isolate
        < rollback_isolate
        < isolation_gate
        < root_crontab_restore
        < snapshot_cron_restore
        < private_config_restore
        < private_log_restore
        < first_restore
    )
    assert "(( isolation_ok == 1 )) || rollback_ok=0" in rollback
    rollback_lines = rollback.splitlines()
    old_isolation = line_number(
        rollback_lines, "require_old_runtime_isolated_stable || rollback_ok=0"
    )
    assert rollback.count("require_old_runtime_isolated_stable || rollback_ok=0") == 1
    activation_lines = [
        index
        for index, line in enumerate(rollback_lines)
        if re.search(r"\bsystemctl\s+(?:enable|start)\b", line)
    ]
    assert activation_lines and old_isolation < min(activation_lines)
    rollback_enable = line_number(
        rollback_lines, "systemctl enable shuzijun-internal-health.timer"
    )
    rollback_verify_enabled = line_number(
        rollback_lines,
        "require_old_runtime_enabled_inactive || rollback_ok=0",
        rollback_enable,
    )
    rollback_start = line_number(
        rollback_lines,
        "systemctl start shuzijun-internal-health.timer",
        rollback_verify_enabled,
    )
    rollback_rearm_reset = line_number(
        rollback_lines,
        "systemctl reset-failed shuzijun-internal-health.service",
        rollback_start,
    )
    rollback_service_start = line_number(
        rollback_lines,
        "systemctl start shuzijun-internal-health.service",
        rollback_rearm_reset,
    )
    rollback_settle = line_number(
        rollback_lines, "settle_timer_schedule || rollback_ok=0", rollback_service_start
    )
    rollback_active_gate = line_number(
        rollback_lines, "require_old_runtime_active || rollback_ok=0", rollback_settle
    )
    assert (
        old_isolation
        < rollback_enable
        < rollback_verify_enabled
        < rollback_start
        < rollback_rearm_reset
        < rollback_service_start
        < rollback_settle
        < rollback_active_gate
    )
    assert "systemctl enable --now" not in rollback
    assert_rollback_isolator_negative_path(rollback)
    assert_rollback_immediate_timer_fire_path(rollback)
    rollback_prepare = line_number(
        rollback_lines, 'prepare_terminal_marker ROLLED_BACK "$rollback_marker"'
    )
    rollback_final_quiescent = line_number(
        rollback_lines,
        'validate_timer_quiescent "$RESTORED_INVOCATION" "$RESTORED_TIMER_TRIGGER"',
        rollback_prepare,
    )
    rollback_commit = line_number(
        rollback_lines, "commit_terminal_marker ROLLED_BACK", rollback_final_quiescent
    )
    assert rollback_prepare < rollback_start < rollback_final_quiescent < rollback_commit
    assert "write_marker ROLLED_BACK" not in rollback
    committed_guard = line_number(
        rollback_lines,
        "if (( TERMINAL_MARKER_COMMITTED == 1 )); then",
        rollback_commit,
    )
    committed_exit = line_number(
        rollback_lines, 'exit "$original_rc"', committed_guard
    )
    fallback_disable = line_number(
        rollback_lines, "systemctl disable --now", committed_exit + 1
    )
    assert rollback_commit < committed_guard < committed_exit < fallback_disable
    assert "verified runtime rollback completed" in rollback
    assert "final isolation state is unverified" in rollback
    assert "verified old timer remains active" in rollback
    assert "trap '' INT TERM HUP" in rollback
    reentry_guard = line_number(rollback_lines, "if (( ROLLBACK_RUNNING != 0 )); then")
    reentry_return = line_number(rollback_lines, "return", reentry_guard)
    signal_mask = line_number(rollback_lines, "trap '' INT TERM HUP", reentry_return)
    running_set = line_number(rollback_lines, "ROLLBACK_RUNNING=1", signal_mask)
    error_clear = line_number(rollback_lines, "trap - ERR", running_set)
    assert reentry_guard < reentry_return < signal_mask < running_set < error_clear
    assert rollback.count("sync_timer_enable_state") >= 2
    assert 'persist_status_snapshot "$rollback_status_sha" "$rollback_status_inode"' in rollback

    main_start = line_number(lines, "# All preflight decisions are repeated")
    main_text = "\n".join(lines[main_start:])
    old_state_gate = line_number(lines, "require_old_state_stable", main_start)
    prepared = line_number(lines, "write_marker PREPARED", main_start)
    disable = line_number(lines, "systemctl disable --now", prepared)
    main_isolate = line_number(lines, "isolate_health_runtime old", disable)
    backup_start = line_number(lines, 'backup_one "$SCRIPT_TARGET"', main_isolate)
    root_crontab_backup = line_number(
        lines, 'capture_root_crontab "$BACKUP_DIR/root-crontab.old"', backup_start
    )
    optional_asset_backup = line_number(
        lines, 'record_optional_asset "$PRIVATE_LOG_CONFIG_TARGET"', root_crontab_backup
    )
    committed = line_number(lines, "write_marker COMMITTED", disable)
    first_install = line_number(
        lines,
        'atomic_install "$STAGE/shuzijun-internal-health"',
        committed,
    )
    private_config_install = line_number(
        lines,
        'atomic_install "$STAGE/shuzijun-private-logs.conf"',
        first_install,
    )
    private_logs_create = line_number(lines, "create_private_logs", private_config_install)
    snapshot_cron_install = line_number(
        lines,
        'atomic_install "$STAGE/tencent-daily-snapshot.cron"',
        private_logs_create,
    )
    root_crontab_migrate = line_number(
        lines, "install_migrated_root_crontab", snapshot_cron_install
    )
    support_validation = line_number(
        lines, "require_new_support_assets", root_crontab_migrate
    )
    status_may_change = line_number(lines, "write_marker STATUS_MAY_CHANGE", first_install)
    timer_start = line_number(lines, "start_disabled_timer_and_settle", status_may_change)
    first_start = line_number(lines, "systemctl start shuzijun-internal-health.service", timer_start)
    accepted = line_number(lines, "write_marker ACCEPTED", first_start)
    enable = line_number(lines, "systemctl enable shuzijun-internal-health.timer", accepted)
    done_prepare = line_number(lines, "prepare_terminal_marker DONE", enable)
    done = line_number(lines, "commit_terminal_marker DONE", done_prepare)
    clear_traps = line_number(lines, "trap - ERR INT TERM HUP", done)
    assert (
        old_state_gate
        < prepared
        < disable
        < main_isolate
        < backup_start
        < root_crontab_backup
        < optional_asset_backup
        < committed
        < first_install
        < private_config_install
        < private_logs_create
        < snapshot_cron_install
        < root_crontab_migrate
        < support_validation
        < status_may_change
    )
    for line in lines[main_start:prepared]:
        assert not re.search(
            r"^\s*systemctl\s+(?:disable|enable|mask|reload|reset-failed|restart|start|stop|try-restart|unmask)\b",
            line,
        ), line
    assert status_may_change < timer_start < first_start < accepted < enable < done < clear_traps
    assert text.count("systemctl stop shuzijun-internal-health.service") == 1
    assert main_text.count("require_new_units_stable") == 2
    pre_pin_evidence = "\n".join(lines[status_may_change:timer_start])
    assert "timer_usec" not in pre_pin_evidence
    assert "InvocationID" not in pre_pin_evidence
    assert "systemctl enable --now" not in main_text
    assert "start_disabled_timer_and_settle" in main_text
    assert 'PREVIOUS_INVOCATION=$PINNED_INVOCATION' in main_text
    assert "classify_timer_activation_evidence" in main_text
    assert "BEFORE_TIMER_TRIGGER" not in main_text
    assert '[[ "$TIMER_ACTIVATION_EVIDENCE" == unchanged ]]' in main_text
    assert '[[ "$TIMER_ACTIVATION_EVIDENCE" == invoked ]]' in main_text
    assert '[[ "$AFTER_INVOCATION" != "$FIRST_INVOCATION" && "$AFTER_TIMER_TRIGGER" != "$PINNED_TIMER_TRIGGER" ]]' in main_text
    assert main_text.count("sync_timer_enable_state") >= 3
    assert main_text.count("persist_status_snapshot") >= 2
    final_exit_pin = line_number(lines, 'FINAL_EXIT_STATUS=$VALIDATED_EXIT_STATUS', enable)
    classification_persist = max(
        index
        for index in range(enable, final_exit_pin)
        if 'persist_status_snapshot "$FINAL_STATUS_SHA" "$FINAL_STATUS_INODE"' in lines[index]
    )
    final_status_healthy = line_number(lines, '0) FINAL_HEALTH_STATUS=healthy ;;', final_exit_pin)
    final_status_degraded = line_number(lines, '2) FINAL_HEALTH_STATUS=degraded ;;', final_status_healthy)
    final_persist = line_number(
        lines,
        'persist_status_snapshot "$FINAL_STATUS_SHA" "$FINAL_STATUS_INODE"',
        done_prepare,
    )
    final_quiescent = line_number(
        lines,
        'validate_timer_quiescent "$FINAL_INVOCATION" "$FINAL_TIMER_TRIGGER"',
        final_persist + 1,
    )
    assert enable < done_prepare < final_persist < final_quiescent < done
    assert classification_persist < final_exit_pin < final_status_healthy < final_status_degraded < done_prepare
    assert lines[final_quiescent + 1].strip() == "commit_terminal_marker DONE"
    assert "write_marker DONE" not in main_text
    assert "status=%s exit=%s" in main_text
    assert '"$FINAL_HEALTH_STATUS" "$FINAL_EXIT_STATUS"' in main_text
    for phase in ("PREPARED", "COMMITTED", "STATUS_MAY_CHANGE", "ACCEPTED"):
        assert f"write_marker {phase}" in main_text

    assert "ROOT_BASHPID=$BASHPID" in lines
    assert "readonly ROOT_BASHPID" in lines
    on_error = function_body(lines, "on_error", "on_signal")
    assert "BASHPID != ROOT_BASHPID" in on_error
    signal_start = line_number(lines, "on_signal() {")
    signal_end = line_number(lines, "trap 'on_error' ERR", signal_start + 1)
    signal_body = "\n".join(lines[signal_start:signal_end])
    assert "BASHPID != ROOT_BASHPID" in signal_body
    assert "trap '' INT TERM HUP" in signal_body

    # No application, database, proxy, sync, failover or CDN service may be
    # started, stopped or reconfigured by this narrowly scoped transaction.
    mutation_verbs = {
        "disable",
        "enable",
        "mask",
        "reload",
        "reset-failed",
        "restart",
        "start",
        "stop",
        "try-restart",
        "unmask",
    }
    for line in lines:
        stripped = line.strip()
        match = re.match(r"systemctl\s+([a-z-]+)\b", stripped)
        if match and match.group(1) in mutation_verbs:
            assert "shuzijun-internal-health" in stripped, stripped
    for forbidden in (
        "nginx -s",
        "nginx -t",
        "php-fpm",
        "mysqladmin",
        "wp core",
        "wp db",
        "systemctl restart nginx",
        "systemctl restart php",
        "systemctl restart mysql",
        "systemctl start shuzijun-sync",
        "systemctl enable shuzijun-sync",
        "systemctl start shuzijun-failover",
        "systemctl enable shuzijun-failover",
    ):
        assert forbidden not in text, forbidden

    print("health-monitor-deployer-contract-test: passed")


if __name__ == "__main__":
    main()
