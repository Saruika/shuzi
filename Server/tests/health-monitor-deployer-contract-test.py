import ast
import hashlib
import json
import re
import shlex
import subprocess
from pathlib import Path


DEPLOYER = Path("Server/operations/deploy-shuzijun-health-monitor")
HEALTH_SCRIPT = Path("Server/operations/shuzijun-internal-health")
HEALTH_SERVICE = Path("Server/operations/shuzijun-internal-health.service")
HEALTH_TIMER = Path("Server/operations/shuzijun-internal-health.timer")
INTERNAL_HEALTH_TEST = Path("Server/tests/internal-health-contract-test.py")
OPERATIONS_README = Path("Server/operations/README.md")
RELEASE = Path("Server/releases/v1.5.10-build41.13.md")


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
        ActiveState)
            [[ "$unit" == *.timer ]] && printf '%s\\n' "$TIMER_STATE" || printf '%s\\n' "$SERVICE_STATE"
            ;;
        SubState)
            [[ "$unit" == *.timer ]] && printf '%s\\n' "$TIMER_SUBSTATE" || printf '%s\\n' "$SERVICE_SUBSTATE"
            ;;
        Job|DropInPaths|ExecCondition|ExecStartPre|ExecStartPost|ExecReload|ExecStop|ExecStopPost|SuccessExitStatus)
            printf '\\n'
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


def assert_stopped_service_normalizer_contract(normalizer: str) -> None:
    for reset_rc, load_state, state, substate, job, should_pass in (
        (0, "loaded", "inactive", "dead", "", True),
        (5, "loaded", "inactive", "dead", "", True),
        (5, "not-found", "inactive", "dead", "", False),
        (5, "masked", "inactive", "dead", "", False),
        (5, "loaded", "failed", "failed", "", False),
        (5, "loaded", "active", "running", "", False),
        (5, "loaded", "inactive", "dead", "queued-job", False),
    ):
        invocation = "normalize_stopped_health_service"
        expectation = invocation if should_pass else f"if {invocation}; then exit 97; fi"
        harness = f"""
set -Eeuo pipefail
RESET_RC={reset_rc}
LOAD_STATE={load_state}
STATE={state}
SUBSTATE={substate}
JOB={job}
systemctl() {{
    [[ "$1" == reset-failed && "$2" == shuzijun-internal-health.service ]]
    return "$RESET_RC"
}}
unit_value() {{
    [[ "$1" == shuzijun-internal-health.service ]]
    case "$2" in
        LoadState) printf '%s\\n' "$LOAD_STATE" ;;
        ActiveState) printf '%s\\n' "$STATE" ;;
        SubState) printf '%s\\n' "$SUBSTATE" ;;
        Job) printf '%s\\n' "$JOB" ;;
        *) return 71 ;;
    esac
}}
{normalizer}
{expectation}
"""
        subprocess.run(["/bin/bash", "-c", harness], check=True)

    drift = f"""
set -Eeuo pipefail
second_sample=0
systemctl() {{ return 5; }}
sleep() {{ second_sample=1; }}
unit_value() {{
    [[ "$1" == shuzijun-internal-health.service ]]
    case "$2" in
        LoadState) printf '%s\\n' loaded ;;
        ActiveState) (( second_sample == 0 )) && printf '%s\\n' inactive || printf '%s\\n' active ;;
        SubState) (( second_sample == 0 )) && printf '%s\\n' dead || printf '%s\\n' running ;;
        Job) printf '\\n' ;;
        *) return 71 ;;
    esac
}}
{normalizer}
if normalize_stopped_health_service; then
    exit 98
fi
"""
    subprocess.run(["/bin/bash", "-c", drift], check=True)

    read_failure = f"""
set -Eeuo pipefail
second_sample=0
systemctl() {{ return 5; }}
sleep() {{ second_sample=1; }}
unit_value() {{
    (( second_sample == 0 )) || return 72
    case "$2" in
        LoadState) printf '%s\\n' loaded ;;
        ActiveState) printf '%s\\n' inactive ;;
        SubState) printf '%s\\n' dead ;;
        Job) printf '\\n' ;;
        *) return 71 ;;
    esac
}}
{normalizer}
if normalize_stopped_health_service; then
    exit 99
fi
"""
    subprocess.run(["/bin/bash", "-c", read_failure], check=True)


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
normalize_stopped_health_service() {{ return 0; }}
require_old_runtime_isolated() {{ return 97; }}
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
normalize_stopped_health_service() {{
    service_failed=0
    printf '%s\n' NORMALIZE >&3
    return 0
}}
require_old_runtime_isolated() {{ (( service_busy == 0 && service_failed == 0 )); }}
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
    assert events.count("NORMALIZE") == 1, events
    assert sum(event.startswith("reset-failed shuzijun-internal-health.service") for event in events) == 1, events
    assert sum(event.startswith("start shuzijun-internal-health.service") for event in events) == 1, events


def main() -> None:
    deployer_bytes = DEPLOYER.read_bytes()
    deployer_sha256 = hashlib.sha256(deployer_bytes).hexdigest()
    text = deployer_bytes.decode("utf-8")
    lines = text.splitlines()
    readme = OPERATIONS_README.read_text(encoding="utf-8")
    release = RELEASE.read_text(encoding="utf-8")
    test_sha256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    health_script_sha256 = hashlib.sha256(HEALTH_SCRIPT.read_bytes()).hexdigest()
    health_service_sha256 = hashlib.sha256(HEALTH_SERVICE.read_bytes()).hexdigest()
    health_timer_sha256 = hashlib.sha256(HEALTH_TIMER.read_bytes()).hexdigest()
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

    for fixed_value in (
        "RELEASE_ID=build41.13",
        "DEPLOYER_PATH=/run/deploy-shuzijun-health-build41.13",
        "STAGE=/run/shuzijun-health-build41.13-$NODE",
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
        "NEW_SCRIPT_SHA=c7630bdc54dc7d869c16cf0ba6856f341668a74689724c532a9058711837e945",
        "NEW_SERVICE_SHA=0dd8ab87398735292e9edd64a9fc57d8edf5097d499c4ba5680d7a2d4c2c80dc",
        "NEW_TIMER_SHA=c7e1137ffd0df3fb8a37df08bfe4876b33ec4d92078e9ea4b94ec646a4a9ce3e",
        "OLD_SCRIPT_SHA=71698f025ff467f837e8b7430b4188d05576d2010f9c4f181eea1e56625ca390",
        "OLD_SERVICE_SHA=db95b5410561ce9e0cca235b7faf09e16d4a954c3c593565681cca49221c9537",
        "OLD_TIMER_SHA=ed73e59758978970bf83269dd97e57763e7e1e62c06a26628105066f21f143b6",
        "APP_MANIFEST_SHA=76f1591503d2bb11005d50f0429171b638caac40246be10ab260c500a63cabe9",
        "APP_PLUGIN_SHA=90d50b197ad39e2efb45d2e394f6926c0c1f01d501ef95e4a21de18bd8581fa3",
    ):
        assert fixed_value in lines, fixed_value
    assert f"NEW_SCRIPT_SHA={health_script_sha256}" in lines
    assert f"NEW_SERVICE_SHA={health_service_sha256}" in lines
    assert f"NEW_TIMER_SHA={health_timer_sha256}" in lines
    assert f"HEALTH_SCRIPT_SHA256={health_script_sha256}" in release
    assert f"INTERNAL_HEALTH_TEST_SHA256={internal_health_test_sha256}" in release
    assert f"HEALTH_SERVICE_SHA256={health_service_sha256}" in release
    assert f"HEALTH_TIMER_SHA256={health_timer_sha256}" in release
    assert "DOC_COMMIT" not in text
    assert "SHORT_COMMIT" not in text
    assert "build41.12" not in text
    assert "build41.11" not in text
    assert "build41.10" not in text
    assert "build41.9" not in text
    assert "build41.8" not in text
    assert "build41.7" not in text
    assert "[[ $# -eq 2 ]]" in text
    assert '[[ "$0" == "$DEPLOYER_PATH" ]]' in text

    # The first root execution is externally anchored to the versioned bytes.
    # Self-hashing then records exactly what reached the transaction journal.
    for document in (readme, release):
        assert f"DEPLOYER_SHA256={deployer_sha256}" in document
        assert "/usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin" in document
        assert "LC_ALL=C LANG=C /bin/bash --noprofile --norc -c" in document
        assert "regular file:0:0:700:1" in document
        assert "/usr/bin/realpath -e" in document
        assert "/usr/bin/sha256sum" in document
        assert 'exec /bin/bash --noprofile --norc "$DEPLOYER"' in document
        assert "不得直接执行仓库副本" in document
    assert f"CONTRACT_TEST_SHA256={test_sha256}" in release

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
    assert "directory:0:0:700" in text
    lock_prelude = "\n".join(lines[: line_number(lines, 'flock -n 9') + 1])
    assert 'if [[ -e "$LOCK_FILE" || -L "$LOCK_FILE" ]]' in lock_prelude
    assert lock_prelude.count('[[ ! -L "$LOCK_FILE" && -f "$LOCK_FILE" ]]') == 2
    assert lock_prelude.count('[[ "$(realpath -e -- "$LOCK_FILE")" == "$LOCK_FILE" ]]') == 2
    assert lock_prelude.count("stat -c '%u:%g:%a:%h' -- \"$LOCK_FILE\"") == 2
    assert "stat -c '%F:%u:%g:%a:%h' \"$LOCK_FILE\"" not in lock_prelude
    assert lock_prelude.count("'0:0:600:1'") == 2
    assert "flock -n 9" in text

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
    assert "symbolic link:0:0:777:1" in enabled_link
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
        lines, "require_old_runtime_isolated", "require_old_runtime_enabled_inactive"
    )
    old_active = function_body(lines, "require_old_runtime_active", "require_stage")
    new_units = function_body(lines, "require_new_units", "marker_matches")
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
    assert 'require_exact_exec_start "$SERVICE_OBJECT_PATH" /usr/local/sbin/shuzijun-internal-health /usr/local/sbin/shuzijun-internal-health || return 1' in old_loaded
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

    # The health runtime treats shared /var/log evidence as untrusted. The
    # deployer must never mutate that OS-managed namespace or its files.
    assert "harden_logs" not in text
    assert "/var/log" not in text
    assert "os.fchmod" not in text and "os.fchown" not in text

    validate_status = function_body(lines, "validate_status", "validate_last_invocation")
    expected_match = re.search(
        r"expected = (\{.*?\n\})\nlegacy_role, reasons = expected\[role\]",
        validate_status,
        re.DOTALL,
    )
    assert expected_match is not None
    assert ast.literal_eval(expected_match.group(1)) == {
        "authority": (
            "primary",
            [
                "authority_sync_generation_missing_or_invalid",
                "snapshot_last_success_untrusted_or_stale",
                "sync_last_success_untrusted_or_stale",
                "sync_log_generation_missing_or_invalid",
                "sync_timer_missing_or_disabled",
            ],
        ),
        "standby": (
            "backup",
            [
                "snapshot_last_success_untrusted_or_stale",
                "standby_failover_state_unhealthy_or_stale",
                "standby_failover_timer_disabled",
                "standby_sync_generation_missing_or_invalid",
                "sync_last_success_untrusted_or_stale",
                "sync_log_generation_missing_or_invalid",
            ],
        ),
    }
    assert 'payload.get("operation_reasons") != reasons' in validate_status

    idle = function_body(lines, "wait_health_idle", "normalize_stopped_health_service")
    assert idle.count("ActiveState") >= 2
    assert idle.count("Job") >= 2
    assert "state_again" in idle and "job_again" in idle
    stopped_normalizer = function_body(
        lines, "normalize_stopped_health_service", "require_old_state_stable"
    )
    assert "if systemctl reset-failed shuzijun-internal-health.service; then" in stopped_normalizer
    assert "for sample in 1 2" in stopped_normalizer
    assert "LoadState" in stopped_normalizer
    assert "ActiveState" in stopped_normalizer
    assert "SubState" in stopped_normalizer
    assert "Job" in stopped_normalizer
    assert_stopped_service_normalizer_contract(stopped_normalizer)
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

    validator = function_body(lines, "validate_last_invocation", "require_new_units")
    assert "outer_start_mono=$6 outer_end_mono=$7" in validator
    assert "service_usec ExecMainStartTimestamp" in validator
    assert "service_usec ExecMainExitTimestampMonotonic" in validator
    assert "start_wall * 1000 >= start_ns" in validator
    assert "exit_mono * 1000 <= outer_end_mono" in validator
    assert 'validate_status "$previous_inode" "$previous_sha" "$((start_wall * 1000))" "$((exit_wall * 1000))"' in validator
    assert "VALIDATED_INVOCATION=$invocation" in validator
    assert validator.count("|| return 1") >= 18
    assert_validator_negative_path(validator)
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
    rollback_stop = line_number(
        rollback.splitlines(), "systemctl stop shuzijun-internal-health.service", isolate
    )
    rollback_reset = line_number(
        rollback.splitlines(),
        "normalize_stopped_health_service",
        rollback_stop,
    )
    isolation_gate = line_number(rollback.splitlines(), "if (( isolation_ok == 1 ))")
    first_restore = line_number(rollback.splitlines(), "atomic_restore")
    assert isolate < rollback_stop < rollback_reset < isolation_gate < first_restore
    assert "(( isolation_ok == 1 )) || rollback_ok=0" in rollback
    rollback_lines = rollback.splitlines()
    old_isolation = line_number(
        rollback_lines, "require_old_runtime_isolated || rollback_ok=0"
    )
    assert rollback.count("require_old_runtime_isolated || rollback_ok=0") == 1
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
    main_stop = line_number(
        lines, "systemctl stop shuzijun-internal-health.service", disable
    )
    main_reset = line_number(
        lines,
        "normalize_stopped_health_service",
        main_stop,
    )
    main_service_inactive = line_number(
        lines,
        '[[ "$(systemctl is-active shuzijun-internal-health.service)" == inactive ]]',
        main_reset,
    )
    backup_start = line_number(lines, 'backup_one "$SCRIPT_TARGET"', main_service_inactive)
    committed = line_number(lines, "write_marker COMMITTED", disable)
    first_install = line_number(
        lines,
        'atomic_install "$STAGE/shuzijun-internal-health"',
        committed,
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
        < main_stop
        < main_reset
        < main_service_inactive
        < backup_start
        < committed
        < first_install
        < status_may_change
    )
    for line in lines[main_start:prepared]:
        assert not re.search(
            r"^\s*systemctl\s+(?:disable|enable|mask|reload|reset-failed|restart|start|stop|try-restart|unmask)\b",
            line,
        ), line
    assert status_may_change < timer_start < first_start < accepted < enable < done < clear_traps
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
    assert lines[final_quiescent + 1].strip() == "commit_terminal_marker DONE"
    assert "write_marker DONE" not in main_text
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
