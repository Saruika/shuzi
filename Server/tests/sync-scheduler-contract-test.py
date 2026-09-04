#!/usr/bin/env python3
"""Static contract for the primary-node WordPress sync scheduler."""

import hashlib
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import tempfile
import time


SERVICE = Path("Server/operations/shuzijun-sync.service")
SENDER = Path("Server/operations/sync-to-backup")
PREFLIGHT = Path("Server/operations/shuzijun-sync-preflight.service")
TIMER = Path("Server/operations/shuzijun-sync.timer")
FPM_GUARD = Path("Server/operations/shuzijun-sync-fpm-guard.service")
STATIC_VERIFY = Path("Server/operations/verify-shuzijun-sync-source")
FULL_VERIFY = Path("Server/operations/verify-webroot-security")
README = Path("Server/operations/README.md")


def directives(path: Path) -> dict[str, list[str]]:
    result: dict[str, list[str]] = {}
    section = ""
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        assert section, f"directive outside a section in {path}: {line}"
        assert "=" in line, f"malformed directive in {path}: {line}"
        key, value = line.split("=", 1)
        result.setdefault(f"{section}.{key}", []).append(value)
    return result


def require_exact(unit: dict[str, list[str]], key: str, value: str) -> None:
    assert unit.get(key) == [value], f"{key} must be exactly {value!r}"


def shell_function(text: str, name: str) -> str:
    start = text.index(f"{name}() {{")
    end = text.index("\n}\n", start) + 3
    return text[start:end]


def test_real_systemd255_failure_boundaries() -> None:
    """Opt-in destructive-to-fixtures-only validation on a real systemd 255 host."""
    if os.environ.get("SHUZIJUN_RUN_SYSTEMD255_FIXTURE") != "1":
        return
    assert sys.platform == "linux" and os.geteuid() == 0
    version = subprocess.run(
        ["/usr/bin/systemd", "--version"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=5,
        check=True,
    ).stdout.splitlines()[0]
    assert version.startswith("systemd 255"), version

    token = secrets.token_hex(6)
    prefix = f"codex-sync255-{token}"
    runtime = Path("/run") / prefix
    runtime.mkdir(mode=0o700)
    worker = runtime / "worker"
    worker.write_text(
        "#!/bin/bash\n"
        "set -euo pipefail\n"
        "mode=$1\nroot=$2\n"
        "case $mode in\n"
        "  term) trap 'exit 0' TERM; : > \"$root/ready\"; "
        "while :; do sleep 0.1; done ;;\n"
        "  kill) trap '' TERM; : > \"$root/ready\"; "
        "while :; do sleep 0.1; done ;;\n"
        "  delayed) trap 'sleep 2; exit 0' TERM; : > \"$root/ready\"; "
        "while :; do sleep 0.1; done ;;\n"
        "  fail) exit 19 ;;\n"
        "  guard)\n"
        "    test -f \"$root/commit\" && test ! -L \"$root/commit\" || exit 77\n"
        "    /usr/bin/test \"$(/usr/bin/stat -c '%u:%g:%h:%a:%s' \"$root/commit\")\" "
        "= '0:0:1:600:10' || exit 77\n"
        "    /usr/bin/cmp -s \"$root/commit\" \"$root/expected\" || exit 77\n"
        "    /usr/bin/systemd-notify --ready\n"
        "    trap 'exit 0' TERM\n"
        "    while :; do sleep 0.1; done ;;\n"
        "  app) : > \"$root/app-started\"; trap 'exit 0' TERM; "
        "while :; do sleep 0.1; done ;;\n"
        "  *) exit 2 ;;\n"
        "esac\n",
        encoding="utf-8",
    )
    worker.chmod(0o700)
    expected = runtime / "expected"
    expected.write_bytes(b"committed\n")
    expected.chmod(0o600)

    unit_root = Path("/run/systemd/system")
    units: list[str] = []

    def add_unit(label: str, body: str) -> str:
        name = f"{prefix}-{label}.service"
        path = unit_root / name
        path.write_text(body, encoding="utf-8")
        path.chmod(0o644)
        units.append(name)
        return name

    common = (
        "[Unit]\nStartLimitIntervalSec=10s\nStartLimitBurst=2\n"
        "[Service]\nType=exec\nUser=root\nGroup=root\nUMask=0077\n"
        "KillMode=control-group\n"
    )
    term = add_unit(
        "term", common + f"ExecStart=/bin/bash {worker} term {runtime}\nTimeoutStopSec=3s\n"
    )
    killed = add_unit(
        "kill", common + f"ExecStart=/bin/bash {worker} kill {runtime}\nTimeoutStopSec=1s\n"
    )
    stopped = add_unit(
        "sigstop", common + f"ExecStart=/bin/bash {worker} kill {runtime}\nTimeoutStopSec=1s\n"
    )
    delayed = add_unit(
        "delayed", common + f"ExecStart=/bin/bash {worker} delayed {runtime}\nTimeoutStopSec=5s\n"
    )
    runtime_max = add_unit(
        "runtime", common + f"ExecStart=/bin/bash {worker} kill {runtime}\n"
        "RuntimeMaxSec=1s\nTimeoutStopSec=1s\n"
    )
    start_limit = add_unit(
        "startlimit",
        common
        + f"ExecStart=/bin/bash {worker} fail {runtime}\nRestart=on-failure\nRestartSec=100ms\n",
    )
    guard = add_unit(
        "guard",
        "[Unit]\n"
        + f"Before={prefix}-app.service\n"
        + "[Service]\nType=notify\nNotifyAccess=all\n"
        + f"ExecStart=/bin/bash {worker} guard {runtime}\nTimeoutStartSec=3s\n"
        + "TimeoutStopSec=2s\nRestart=no\n",
    )
    app = add_unit(
        "app",
        "[Unit]\n"
        + f"Requires={guard}\nAfter={guard}\n"
        + "[Service]\nType=exec\n"
        + f"ExecStart=/bin/bash {worker} app {runtime}\nTimeoutStopSec=2s\n",
    )

    def ctl(*arguments: str, timeout: float = 15) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/usr/bin/systemctl", *arguments],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )

    def show(name: str) -> dict[str, str]:
        result = ctl(
            "show", name,
            "--property=LoadState", "--property=ActiveState",
            "--property=SubState", "--property=Result", "--property=MainPID",
        )
        assert result.returncode == 0, result.stderr
        return dict(line.split("=", 1) for line in result.stdout.splitlines())

    def wait_for(name: str, predicate, timeout: float = 8) -> dict[str, str]:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            state = show(name)
            if predicate(state):
                return state
            time.sleep(0.1)
        raise AssertionError((name, show(name)))

    try:
        assert ctl("daemon-reload").returncode == 0

        started_result = ctl("start", term)
        assert started_result.returncode == 0, started_result.stderr
        before = time.monotonic()
        assert ctl("stop", term).returncode == 0
        assert time.monotonic() - before < 3

        assert ctl("start", killed).returncode == 0
        before = time.monotonic()
        assert ctl("stop", killed).returncode == 0
        assert 0.8 <= time.monotonic() - before < 4

        assert ctl("start", stopped).returncode == 0
        stopped_state = show(stopped)
        stopped_pid = int(stopped_state["MainPID"])
        assert stopped_pid > 1
        os.kill(stopped_pid, signal.SIGSTOP)
        before = time.monotonic()
        assert ctl("stop", stopped).returncode == 0
        assert 0.8 <= time.monotonic() - before < 4
        try:
            os.kill(stopped_pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("SIGSTOP fixture process survived systemd stop")

        assert ctl("start", delayed).returncode == 0
        before = time.monotonic()
        assert ctl("stop", delayed).returncode == 0
        assert 1.5 <= time.monotonic() - before < 5

        assert ctl("start", runtime_max).returncode == 0
        runtime_state = wait_for(
            runtime_max,
            lambda value: value["ActiveState"] == "failed",
            timeout=6,
        )
        assert runtime_state["Result"] == "timeout", runtime_state

        start_limit_rejected = False
        for _attempt in range(6):
            attempted = ctl("start", start_limit)
            if "repeated too quickly" in attempted.stderr:
                start_limit_rejected = True
            time.sleep(0.1)
        journal = subprocess.run(
            [
                "/usr/bin/journalctl", "--no-pager", "-n", "30", "-o", "cat",
                "-u", start_limit,
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        start_limit_rejected = start_limit_rejected or (
            "Start request repeated too quickly" in journal.stdout
        )
        limited = show(start_limit)
        assert start_limit_rejected and limited["ActiveState"] == "failed", limited

        # Armed/missing and malformed commits must block the dependent app.
        commit = runtime / "commit"
        rejected = ctl("start", app, timeout=8)
        assert rejected.returncode != 0 and not (runtime / "app-started").exists()
        ctl("reset-failed", guard, app)
        commit.write_bytes(b"corrupt!!\n")
        commit.chmod(0o600)
        rejected = ctl("start", app, timeout=8)
        assert rejected.returncode != 0 and not (runtime / "app-started").exists()
        ctl("reset-failed", guard, app)

        # Exact atomically published commit releases the Required+Before gate.
        temporary = runtime / (".commit." + secrets.token_hex(16))
        temporary.write_bytes(b"committed\n")
        temporary.chmod(0o600)
        descriptor = os.open(temporary, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        os.replace(temporary, commit)
        directory = os.open(runtime, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        accepted = ctl("start", app, timeout=8)
        assert accepted.returncode == 0, accepted.stderr
        app_marker = runtime / "app-started"
        marker_deadline = time.monotonic() + 2
        while time.monotonic() < marker_deadline and not app_marker.exists():
            time.sleep(0.02)
        assert app_marker.exists(), (show(guard), show(app))
    finally:
        for name in reversed(units):
            ctl("stop", name, timeout=8)
            ctl("reset-failed", name)
            try:
                (unit_root / name).unlink()
            except FileNotFoundError:
                pass
        ctl("daemon-reload")
        import shutil
        shutil.rmtree(runtime, ignore_errors=True)


def static_transform_program(static_verify_text: str) -> str:
    """Return the exact Python program supplied to the production fd 8."""
    command = "/usr/bin/python3 -I /proc/self/fd/8 \"$VERIFY_FD\" 8<<'PY'"
    command_offset = static_verify_text.index(command)
    program_offset = static_verify_text.index("\nimport os\n", command_offset) + 1
    terminator_offset = static_verify_text.index("\nPY\n", program_offset)
    program = static_verify_text[program_offset : terminator_offset + 1]
    assert "\nPY\n" not in program
    return program


def run_fd_transform(
    temp: Path,
    program: str,
    verifier_source: bytes,
    case: str,
) -> tuple[subprocess.CompletedProcess[str], Path, Path]:
    """Execute the fd8 transformer -> Bash pipeline against an offline fixture."""
    case_dir = temp / case
    case_dir.mkdir()
    verifier = case_dir / "verifier"
    verifier.write_bytes(verifier_source)
    marker = case_dir / "commands-ran"
    fake_bin = case_dir / "bin"
    fake_bin.mkdir()
    nginx_calls = fake_bin / "nginx.calls"
    fake_nginx = fake_bin / "nginx"
    fake_nginx.write_text(
        "#!/bin/bash\n"
        "set -eu\n"
        f"printf 'called\\n' >> {str(nginx_calls)!r}\n",
        encoding="utf-8",
    )
    fake_nginx.chmod(0o755)

    fd_root = "/proc/self/fd" if Path("/proc/self/fd").is_dir() else "/dev/fd"
    harness = case_dir / "run-transform"
    harness.write_text(
        "#!/bin/bash\n"
        "set -euo pipefail\n"
        "PATH=\"$2\"\n"
        "export PATH\n"
        "exec 9<\"$1\"\n"
        f"env -i PATH=\"$2\" LC_ALL=C LANG=C {sys.executable!r} -I "
        f"{fd_root}/8 {fd_root}/9 8<<'PY' | "
        "/bin/bash --noprofile --norc -s -- \"$3\"\n"
        f"{program}"
        "PY\n",
        encoding="utf-8",
    )
    harness.chmod(0o755)
    clean_path = f"{fake_bin}:/usr/sbin:/usr/bin:/sbin:/bin"
    result = subprocess.run(
        [str(harness), str(verifier), clean_path, str(marker)],
        cwd=case_dir,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={"PATH": "/usr/bin:/bin"},
        check=False,
    )
    return result, marker, nginx_calls


def test_static_transform_behavior(static_verify_text: str) -> None:
    """Exercise the real fd8 Python transformation, not a reimplementation."""
    program = static_transform_program(static_verify_text)
    needle = (
        b"nginx -t >/dev/null\n\n"
        b"printf 'webroot-security: passed\\n'\n"
    )
    prefix = (
        b"#!/bin/bash\n"
        b"set -eu\n"
        b"printf 'prefix-ran\\n' >> \"$1\"\n"
        # This non-boundary invocation must remain executable.  Only the final
        # reviewed boundary below is eligible for replacement.
        b"nginx -t >/dev/null\n"
        b"printf 'middle-ran\\n' >> \"$1\"\n"
    )

    with tempfile.TemporaryDirectory(prefix="sync-static-verifier-test-") as raw:
        temp = Path(raw)
        normal, marker, nginx_calls = run_fd_transform(
            temp, program, prefix + needle, "normal"
        )
        assert normal.returncode == 0, normal.stderr
        assert normal.stdout == "webroot-security: static contract passed\n"
        assert marker.read_text(encoding="utf-8") == "prefix-ran\nmiddle-ran\n"
        assert nginx_calls.read_text(encoding="utf-8") == "called\n", (
            "the non-boundary nginx check must run exactly once while the final "
            "reviewed nginx check is replaced"
        )

        missing, missing_marker, missing_calls = run_fd_transform(
            temp,
            program,
            prefix + b"printf 'boundary-missing\\n'\n",
            "missing-boundary",
        )
        assert missing.returncode != 0
        assert "reviewed verifier live-check boundary is not exact" in missing.stderr
        assert missing.stdout == ""
        assert not missing_marker.exists()
        assert not missing_calls.exists()

        duplicate, duplicate_marker, duplicate_calls = run_fd_transform(
            temp, program, prefix + needle + needle, "duplicate-boundary"
        )
        assert duplicate.returncode != 0
        assert "reviewed verifier live-check boundary is not exact" in duplicate.stderr
        assert duplicate.stdout == ""
        assert not duplicate_marker.exists()
        assert not duplicate_calls.exists()

        broken_fd8, broken_marker, broken_calls = run_fd_transform(
            temp,
            "this is not valid Python on fd 8\n",
            prefix + needle,
            "broken-fd8-program",
        )
        assert broken_fd8.returncode != 0, (
            "pipefail must propagate an invalid fd8 transformer instead of "
            "accepting the downstream shell's empty-input success"
        )
        assert "SyntaxError" in broken_fd8.stderr
        assert broken_fd8.stdout == ""
        assert not broken_marker.exists()
        assert not broken_calls.exists()


def test_sender_recovery_mode_behavior(sender_text: str) -> None:
    """Exercise marker-gated recovery without touching the host's systemd."""
    with tempfile.TemporaryDirectory(prefix="sync-sender-restore-test-") as raw:
        temp = Path(raw)
        runtime_root = temp / "shuzijun-sync"
        runtime_root.mkdir(mode=0o700)
        calls = temp / "systemctl.calls"
        state = temp / "fpm.state"
        fake_systemctl = temp / "systemctl"
        fake_systemctl.write_text(
            "#!/bin/bash\n"
            "set -euo pipefail\n"
            f"calls={str(calls)!r}\n"
            f"state={str(state)!r}\n"
            "printf '%s\\n' \"$*\" >> \"$calls\"\n"
            "case $1 in\n"
            "  start)\n"
            "    test \"$2\" = --no-block\n"
            "    test \"$3\" = php8.3-fpm.service\n"
            "    printf 'active\\n' > \"$state\"\n"
            "    ;;\n"
            "  show)\n"
            "    shift\n"
            "    properties=()\n"
            "    value_mode=0\n"
            "    service=\n"
            "    for argument in \"$@\"; do\n"
            "      case $argument in\n"
            "        --property=*) properties+=(\"${argument#--property=}\") ;;\n"
            "        --value) value_mode=1 ;;\n"
            "        *) service=$argument ;;\n"
            "      esac\n"
            "    done\n"
            "    test -n \"$service\"\n"
            "    current=active\n"
            "    if [[ $service = php8.3-fpm.service ]]; then current=$(cat \"$state\"); fi\n"
            "    for property in \"${properties[@]}\"; do\n"
            "      case $property in\n"
            "        LoadState) value=loaded ;;\n"
            "        ActiveState) value=$current ;;\n"
            "        SubState) [[ $current = active ]] && value=running || value=dead ;;\n"
            "        Result) value=success ;;\n"
            "        MainPID) [[ $current = active ]] && value=42 || value=0 ;;\n"
            "        Job) value= ;;\n"
            "        *) exit 1 ;;\n"
            "      esac\n"
            "      if [[ $value_mode -eq 1 ]]; then printf '%s\\n' \"$value\"; "
            "      else printf '%s=%s\\n' \"$property\" \"$value\"; fi\n"
            "    done\n"
            "    ;;\n"
            "  *) exit 1 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        fake_systemctl.chmod(0o755)
        # macOS has no /usr/bin/timeout.  Keep the production helper's argv
        # shape under test while using a transparent fixture runner for these
        # short, non-hanging recovery-mode probes.
        fake_timeout = temp / "timeout"
        fake_timeout.write_text(
            "#!/bin/bash\n"
            "set -euo pipefail\n"
            "while (($#)); do\n"
            "  case $1 in\n"
            "    --signal=*|--kill-after=*) shift ;;\n"
            "    [0-9]*[smh]) shift; break ;;\n"
            "    *) exit 97 ;;\n"
            "  esac\n"
            "done\n"
            "(($#)) || exit 97\n"
            "exec \"$@\"\n",
            encoding="utf-8",
        )
        fake_timeout.chmod(0o755)
        sender = temp / "sync-to-backup"
        transformed = sender_text.replace(
            "FPM_FREEZE_ROOT=/run/shuzijun-sync",
            f"FPM_FREEZE_ROOT={runtime_root}",
        ).replace(
            'root != Path("/run/shuzijun-sync")',
            f"root != Path({str(runtime_root)!r})",
        ).replace(
            "/usr/bin/systemctl", str(fake_systemctl)
        ).replace(
            "/usr/bin/timeout", str(fake_timeout)
        ).replace(
            "/proc/self/fd/9", "-"
        ).replace(
            "9<<'PY'", "<<'PY'"
        ).replace(
            "metadata.st_uid != 0", "metadata.st_uid != os.getuid()"
        ).replace(
            "metadata.st_gid != 0", "metadata.st_gid != os.getgid()"
        )
        sender.write_text(
            transformed,
            encoding="utf-8",
        )
        sender.chmod(0o755)
        environment = {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin"}

        # ExecStopPost also runs when ExecStartPre fails.  With no secure
        # marker, it must be a no-op and must not start an originally inactive
        # PHP-FPM service.
        state.write_text("inactive\n", encoding="ascii")
        no_marker = subprocess.run(
            [str(sender), "--recover-primary-fpm-if-marked"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            check=False,
        )
        assert no_marker.returncode == 0, no_marker.stderr
        assert no_marker.stdout == ""
        assert not calls.exists(), "markerless recovery must not touch services"
        assert state.read_text(encoding="ascii") == "inactive\n"

        import json
        token = "a" * 64
        marker = runtime_root / "primary-fpm-freeze.json"
        document = {
            "created_monotonic_ns": 1,
            "deadline_monotonic_ns": 120_000_000_001,
            "owner_pid": 2,
            "owner_start_ticks": 1,
            "phase": "armed",
            "phase_started_monotonic_ns": 1,
            "token": token,
            "version": 2,
        }
        marker.write_text(
            json.dumps(document, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
            + "\n",
            encoding="ascii",
        )
        marker.chmod(0o600)
        recovered = subprocess.run(
            [str(sender), "--recover-primary-fpm-if-marked"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            check=False,
        )
        assert recovered.returncode == 0, recovered.stderr
        assert recovered.stdout == ""
        assert calls.exists(), (
            f"recovery did not query systemd; marker_exists={marker.exists()} "
            f"state={state.read_text(encoding='ascii')!r} stderr={recovered.stderr!r}"
        )
        recovery_calls = calls.read_text(encoding="utf-8").splitlines()
        assert "start --no-block php8.3-fpm.service" in recovery_calls
        assert state.read_text(encoding="ascii") == "active\n"
        assert not marker.exists(), "the durable marker clears only after recovery"

        # A stop request can outlive the `systemctl stop` client. Recovery must
        # always enqueue a replacement start even if the sampled state still
        # looks active, so a late stop completion cannot strand FPM offline.
        calls.unlink()
        marker.write_text(
            json.dumps(document, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
            + "\n",
            encoding="ascii",
        )
        marker.chmod(0o600)
        state.write_text("active\n", encoding="ascii")
        pending_stop = subprocess.run(
            [str(sender), "--recover-primary-fpm-if-marked"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            check=False,
        )
        assert pending_stop.returncode == 0, pending_stop.stderr
        assert "start --no-block php8.3-fpm.service" in calls.read_text(
            encoding="utf-8"
        ).splitlines()
        assert state.read_text(encoding="ascii") == "active\n"
        assert not marker.exists()

        # A symlink marker must fail closed without starting PHP-FPM.
        state.write_text("inactive\n", encoding="ascii")
        calls.unlink()
        target = temp / "attacker-marker"
        target.write_text("{}\n", encoding="ascii")
        marker.symlink_to(target)
        rejected = subprocess.run(
            [str(sender), "--recover-primary-fpm-if-marked"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            check=False,
        )
        assert rejected.returncode != 0
        assert state.read_text(encoding="ascii") == "inactive\n"
        assert not calls.exists()


def test_sender_condition_context_and_status_behavior(sender_text: str) -> None:
    """Service predicates must not accept malformed PIDs or ambiguous negatives."""
    with tempfile.TemporaryDirectory(prefix="sync-sender-condition-test-") as raw:
        temp = Path(raw)
        fake_timeout = temp / "timeout"
        fake_timeout.write_text(
            "#!/bin/bash\nexit \"${FAKE_TIMEOUT_STATUS:?}\"\n",
            encoding="utf-8",
        )
        fake_timeout.chmod(0o755)

        def run_predicate(
            name: str, snapshot: str, status: int
        ) -> subprocess.CompletedProcess[str]:
            function = shell_function(sender_text, name).replace(
                "/usr/bin/timeout", '"$TIMEOUT"'
            )
            harness = (
                "set -euo pipefail\n"
                + function
                + "\nservice_snapshot() { printf '%s' \"$SNAPSHOT\"; }\n"
                + "FPM_SERVICE=php8.3-fpm.service\n"
                + "if " + name + "; then exit 0; fi\nexit 31\n"
            )
            return subprocess.run(
                ["/bin/bash", "-c", harness, "sender-condition-test"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={
                    "PATH": "/usr/bin:/bin",
                    "TIMEOUT": str(fake_timeout),
                    "FAKE_TIMEOUT_STATUS": str(status),
                    "SNAPSHOT": snapshot,
                },
                check=False,
            )

        active = (
            "LoadState=loaded\nActiveState=active\nSubState=running\n"
            "Result=success\nMainPID=42\nJob=\n"
        )
        assert run_predicate("verify_primary_fpm_active", active, 0).returncode == 0
        for malformed_pid in ("0", "1", "abc", "2x"):
            malformed = active.replace("MainPID=42", f"MainPID={malformed_pid}")
            assert run_predicate(
                "verify_primary_fpm_active", malformed, 0
            ).returncode == 31
            assert run_predicate(
                "verify_primary_nginx_active", malformed, 0
            ).returncode == 31

        inactive = (
            "LoadState=loaded\nActiveState=inactive\nSubState=dead\n"
            "Result=success\nMainPID=0\nJob=\n"
        )
        assert run_predicate("verify_primary_fpm_inactive", inactive, 3).returncode == 0
        for ambiguous_status in (0, 1, 4, 124, 137):
            assert run_predicate(
                "verify_primary_fpm_inactive", inactive, ambiguous_status
            ).returncode == 31

        assert r'cd \"\$1\" || exit 1; wp db export' in sender_text
        marker = temp / "wp-ran"
        bad_directory = temp / "missing"
        export_harness = (
            "set -euo pipefail\n"
            "wp() { : > \"$MARKER\"; printf sql; }\n"
            "bound_database_sql_stream() { cat; }\n"
            "gzip() { cat; }\n"
            "store_staged_database() { cat >/dev/null; }\n"
            "cd \"$1\" || exit 1; wp db export - --add-drop-table --allow-root --quiet "
            "| bound_database_sql_stream | gzip -9 | store_staged_database /tmp 1\n"
        )
        export_result = subprocess.run(
            [
                "/bin/bash", "-o", "pipefail", "-c", export_harness,
                "export-test", str(bad_directory),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin", "MARKER": str(marker)},
            check=False,
        )
        assert export_result.returncode != 0
        assert not marker.exists(), (
            "a failed cd must never export from the prior working directory"
        )

        watchdog_function = shell_function(
            sender_text, "verify_primary_fpm_watchdog_active"
        )

        def run_watchdog(status: int) -> subprocess.CompletedProcess[str]:
            harness = (
                "set -euo pipefail\n"
                + watchdog_function
                + "\nservice_property() {\n"
                + "  case \"$2\" in ActiveState) printf 'active\\n' ;; "
                + "SubState) printf 'running\\n' ;; Result) printf 'success\\n' ;; "
                + "*) return 2 ;; esac\n"
                + "  return \"$PROPERTY_STATUS\"\n}\n"
                + "if verify_primary_fpm_watchdog_active "
                + "shuzijun-primary-fpm-recovery-0123456789abcdef.service; "
                + "then exit 0; fi\nexit 32\n"
            )
            return subprocess.run(
                ["/bin/bash", "-c", harness, "watchdog-property-test"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={"PATH": "/usr/bin:/bin", "PROPERTY_STATUS": str(status)},
                check=False,
            )

        assert run_watchdog(0).returncode == 0
        assert run_watchdog(124).returncode == 32, (
            "watchdog state output followed by timeout/nonzero must fail closed"
        )

    for option in (
        "-o UpdateHostKeys=no",
        "-o ConnectionAttempts=3",
        "-o ConnectTimeout=10",
        "-o ServerAliveInterval=15",
        "-o ServerAliveCountMax=2",
        "-o TCPKeepAlive=yes",
    ):
        assert option in sender_text
    receiver_query = shell_function(sender_text, "receiver_control_query")
    assert "/usr/bin/timeout --signal=TERM --kill-after=5s 60s" in receiver_query
    assert (
        '[[ "$operation" == --attest || "$operation" == --protocol \\\n'
        '        || "$operation" == --reconcile-receipt ]]'
        in receiver_query
    )
    assert sender_text.count("-o ConnectionAttempts=3") == 1
    assert "-o ConnectTimeout=15" not in sender_text
    assert receiver_query.count(
        '"${SSH[@]}" "sudo $REMOTE_RECEIVER $operation"'
    ) == 1
    for forbidden_retry in ("Connection refused", "for ", "while ", "sleep "):
        assert forbidden_retry not in receiver_query
    assert sender_text.count("receiver_control_query --attest") == 2
    assert sender_text.count("receiver_control_query --protocol") == 2
    assert sender_text.count("receiver_control_query --reconcile-receipt") == 1

    if sys.platform == "linux" and Path("/usr/bin/timeout").is_file():
        with tempfile.TemporaryDirectory(prefix="sync-sender-control-timeout-") as raw:
            temp = Path(raw)
            helper = temp / "stalled-ssh"
            pid_file = temp / "grandchild.pid"
            helper.write_text(
                "#!/bin/bash\n"
                "trap '' TERM\n"
                "( trap '' TERM; while :; do sleep 1; done ) &\n"
                "child=$!\n"
                "printf '%s\\n' \"$child\" > \"$PID_FILE\"\n"
                "wait \"$child\"\n",
                encoding="utf-8",
            )
            helper.chmod(0o755)
            shortened = receiver_query.replace(
                "--kill-after=5s 60s", "--kill-after=0.1s 0.2s"
            )
            harness = (
                "set -euo pipefail\n"
                + shortened
                + "\nREMOTE_RECEIVER=/fixture/receiver\nSSH=(\"$HELPER\")\n"
                + "if receiver_control_query --attest; then exit 0; fi\nexit 33\n"
            )
            started = time.monotonic()
            result = subprocess.run(
                ["/bin/bash", "-c", harness, "sender-control-timeout-test"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={
                    "PATH": "/usr/bin:/bin",
                    "HELPER": str(helper),
                    "PID_FILE": str(pid_file),
                },
                timeout=3,
                check=False,
            )
            assert result.returncode == 33, result.stderr
            assert time.monotonic() - started < 2
            child = int(pid_file.read_text(encoding="ascii"))
            for _ in range(50):
                try:
                    os.kill(child, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.02)
            else:
                raise AssertionError(
                    "receiver control deadline left an SSH grandchild alive"
                )


def main() -> None:
    test_real_systemd255_failure_boundaries()
    if os.environ.get("SHUZIJUN_SYSTEMD255_ONLY") == "1":
        assert os.environ.get("SHUZIJUN_RUN_SYSTEMD255_FIXTURE") == "1"
        print("sync-scheduler-contract-test: real systemd255 fixture passed")
        return
    assert SERVICE.is_file() and not SERVICE.is_symlink()
    assert SENDER.is_file() and not SENDER.is_symlink()
    assert PREFLIGHT.is_file() and not PREFLIGHT.is_symlink()
    assert TIMER.is_file() and not TIMER.is_symlink()
    assert FPM_GUARD.is_file() and not FPM_GUARD.is_symlink()
    assert STATIC_VERIFY.is_file() and not STATIC_VERIFY.is_symlink()
    service_text = SERVICE.read_text(encoding="utf-8")
    sender_text = SENDER.read_text(encoding="utf-8")
    preflight_text = PREFLIGHT.read_text(encoding="utf-8")
    timer_text = TIMER.read_text(encoding="utf-8")
    fpm_guard_text = FPM_GUARD.read_text(encoding="utf-8")
    static_verify_text = STATIC_VERIFY.read_text(encoding="utf-8")
    readme_text = README.read_text(encoding="utf-8")
    service = directives(SERVICE)
    preflight = directives(PREFLIGHT)
    timer = directives(TIMER)
    fpm_guard = directives(FPM_GUARD)

    require_exact(service, "Unit.Requires", "shuzijun-sync-preflight.service")
    assert service.get("Unit.After") == [
        "network-online.target mysql.service nginx.service "
        "shuzijun-sync-preflight.service"
    ]

    require_exact(service, "Service.Type", "oneshot")
    require_exact(service, "Service.User", "root")
    require_exact(service, "Service.Group", "root")
    require_exact(service, "Service.UMask", "0077")
    require_exact(
        service,
        "Service.ExecStart",
        "/usr/bin/flock -n /run/shuzijun-sync/sync.lock /usr/local/sbin/sync-to-backup",
    )
    require_exact(
        service,
        "Service.ExecStopPost",
        "/usr/local/sbin/sync-to-backup --recover-primary-fpm-if-marked",
    )
    require_exact(service, "Service.TimeoutStartSec", "8h")
    require_exact(service, "Service.TimeoutStopSec", "1min")
    require_exact(service, "Service.KillMode", "control-group")
    require_exact(service, "Service.Restart", "no")
    require_exact(service, "Service.RuntimeDirectory", "shuzijun-sync")
    require_exact(service, "Service.RuntimeDirectoryMode", "0700")
    require_exact(service, "Service.RuntimeDirectoryPreserve", "yes")

    assert service.get("Service.ExecStartPre") == [
        "/usr/bin/systemctl is-active --quiet mysql.service",
        "/usr/bin/systemctl is-active --quiet nginx.service",
        "/usr/bin/systemctl is-active --quiet php8.3-fpm.service",
        "/usr/bin/test -x /usr/local/sbin/sync-to-backup",
        "/usr/bin/test -x /usr/local/sbin/verify-shuzijun-sync-source",
        "/usr/bin/test -x /usr/local/sbin/verify-shuzijun-webroot-security",
        "/usr/bin/test -f /root/.ssh/shuzijun_sync_ed25519",
        "/usr/bin/test -f /var/lib/shuzijun-sync/highest-issued-generation",
    ]
    assert not any(key.startswith("Unit.Condition") for key in service)
    require_exact(
        service,
        "Unit.RequiresMountsFor",
        "/var/www/html/shuzijun.com.cn /var/lib/shuzijun-sync "
        "/var/lib/shuzijun-logs /run",
    )

    for key, value in (
        ("Service.NoNewPrivileges", "true"),
        ("Service.PrivateTmp", "true"),
        ("Service.PrivateDevices", "true"),
        ("Service.ProtectSystem", "strict"),
        ("Service.ProtectHome", "read-only"),
        (
            "Service.ReadWritePaths",
            "/var/lib/shuzijun-sync /var/lib/shuzijun-logs /run/shuzijun-sync",
        ),
        ("Service.ReadOnlyPaths", "/var/www/html/shuzijun.com.cn"),
        ("Service.ProtectHostname", "true"),
        ("Service.ProtectClock", "true"),
        ("Service.ProtectKernelTunables", "true"),
        ("Service.ProtectKernelModules", "true"),
        ("Service.ProtectKernelLogs", "true"),
        ("Service.ProtectControlGroups", "true"),
        ("Service.RestrictSUIDSGID", "true"),
        ("Service.LockPersonality", "true"),
        ("Service.RestrictRealtime", "true"),
        ("Service.RestrictAddressFamilies", "AF_UNIX AF_INET AF_INET6"),
        ("Service.SystemCallArchitectures", "native"),
    ):
        require_exact(service, key, value)
    require_exact(service, "Service.CapabilityBoundingSet", "")
    require_exact(service, "Service.AmbientCapabilities", "")

    assert "LOG=/var/lib/shuzijun-logs/sync-authority.log" in sender_text
    assert (
        "SYNC_PROTOCOL=shuzijun-sync-receiver-v4-transactional-uploads"
        in sender_text
    )
    assert "/var/log/wp-sync.log" not in sender_text
    assert 'exec >>"$LOG"' not in sender_text
    assert sender_text.count("append_sync_authority_event start") == 1
    assert sender_text.count(
        'append_sync_authority_event completion "$generation"'
    ) == 1
    assert sender_text.count(
        'append_sync_authority_event completion-reconciled "$generation"'
    ) == 1
    assert sender_text.count(
        'append_sync_authority_event not-committed "$generation"'
    ) == 1
    assert 'if event == "start":' in sender_text
    assert 'elif event in {"completion", "completion-reconciled", "not-committed"}:' in sender_text
    assert "os.O_APPEND" in sender_text
    assert "flags | os.O_CREAT | os.O_EXCL" in sender_text
    assert 'getattr(os, "O_NOFOLLOW", 0)' in sender_text
    assert "stat.S_IMODE(opened.st_mode) != 0o600" in sender_text
    assert "opened.st_nlink != 1" in sender_text
    assert '("var", "lib", "shuzijun-logs")' in sender_text
    assert "(index == 2 and mode != 0o700)" in sender_text
    assert "metadata.st_uid != 0" in sender_text
    assert "metadata.st_gid != 0" in sender_text
    assert 'PENDING_RECEIPT_STATE="$GENERATION_ROOT/pending-receipt-v5.json"' in sender_text
    assert 'LAST_RECEIPT_RESOLUTION="$GENERATION_ROOT/last-resolution-v5.json"' in sender_text
    assert '"evidence_sha256", "expected_release_id", "generation",' in sender_text
    assert '"ingest_receiver_sha256", "protocol", "version",' in sender_text
    assert "INGEST_RECEIPT_HEX=$(" in sender_text
    assert "capture_control_stdout_hex" in sender_text
    assert "printf -v EXPECTED_INGEST_RECEIPT" in sender_text
    assert (
        "sync-applied generation=%s receiver-sha256=%s protocol=%s "
        "cache=flushed signed=true uploads-only=true\\n"
        in sender_text
    )
    assert (
        '"$GENERATION" "$REMOTE_RECEIVER_SHA256" "$SYNC_PROTOCOL"'
        in sender_text
    )
    assert (
        'if [[ "$INGEST_STATUS" -eq 0 \\\n'
        '    && "$INGEST_RECEIPT_HEX" == "$EXPECTED_INGEST_RECEIPT_HEX" ]]; then'
        in sender_text
    )
    assert "sync-reconcile-v5 accepted=([1-9][0-9]{0,18})" in sender_text
    assert r"transaction=none runtime=(healthy|isolated)\n" in sender_text
    assert "FPM_SERVICE=php8.3-fpm.service" in sender_text
    assert '"$1" == --recover-primary-fpm-if-marked' in sender_text
    assert '"$1" == --watch-primary-fpm' in sender_text
    assert "verify_primary_fpm_active()" in sender_text
    assert "verify_primary_fpm_inactive()" in sender_text
    assert "verify_primary_nginx_active()" in sender_text
    assert "trap cleanup_sender EXIT" in sender_text
    assert "FPM_FREEZE_ROOT=/run/shuzijun-sync" in sender_text
    assert "FPM_FREEZE_ARM_LIMIT_SECONDS=120" in sender_text
    assert "FPM_FREEZE_LIMIT_SECONDS=180" in sender_text
    assert "primary_fpm_freeze_state()" in sender_text
    assert "FPM_FREEZE_TOKEN=$(primary_fpm_freeze_state create '' \"$$\")" in sender_text
    assert 'primary_fpm_freeze_state recover "$FPM_FREEZE_TOKEN"' in sender_text
    assert "/usr/bin/systemd-run --quiet --collect" in sender_text
    assert "--property=RuntimeMaxSec=7min" in sender_text
    assert "--property=ReadWritePaths=/run/shuzijun-sync" in sender_text
    assert "--property=CapabilityBoundingSet=" in sender_text
    assert "--foreground" not in sender_text
    assert '/usr/bin/systemctl stop "$FPM_SERVICE"' in sender_text
    assert '/usr/bin/systemctl start "$FPM_SERVICE"' not in sender_text
    media_stage = sender_text.index(
        "STAGED_UPLOAD_SNAPSHOT=$("
    )
    frozen_mark = sender_text.index("FPM_FREEZE_TOKEN=$(", media_stage)
    fpm_stop = sender_text.index('/usr/bin/systemctl stop "$FPM_SERVICE"')
    frozen_deadline = sender_text.index(
        'primary_fpm_freeze_state begin-frozen "$FPM_FREEZE_TOKEN"', fpm_stop
    )
    frozen_snapshot = sender_text.index(
        r'audit_or_stage_uploads snapshot \"\$2\" \"\$3\"', fpm_stop
    )
    snapshot_match = sender_text.index(
        'test "$FROZEN_UPLOAD_SNAPSHOT" = "$STAGED_UPLOAD_SNAPSHOT"',
        frozen_snapshot,
    )
    database_export = sender_text.index(
        "wp db export - --add-drop-table --allow-root --quiet"
    )
    fpm_restore = sender_text.index(
        'primary_fpm_freeze_state recover "$FPM_FREEZE_TOKEN"', database_export
    )
    recovered_mark = sender_text.index("FPM_FREEZE_TOKEN=", fpm_restore)
    generation_issue = sender_text.index("GENERATION=$(issue_generation)")
    sender_sign = sender_text.index("ssh-keygen -Y sign", generation_issue)
    pending_receipt = sender_text.index(
        'manage_receipt_state create "$GENERATION" "$MANIFEST_SHA256"', sender_sign
    )
    receiver_ingest = sender_text.index('"sudo $REMOTE_RECEIVER --ingest"')
    assert media_stage < frozen_mark < fpm_stop < frozen_deadline
    assert frozen_deadline < frozen_snapshot < snapshot_match
    assert snapshot_match < database_export < fpm_restore
    assert fpm_restore < recovered_mark < generation_issue < sender_sign
    assert sender_sign < pending_receipt < receiver_ingest
    assert r'store_staged_database \"\$2\" \"\$3\"' in sender_text
    assert "upload_bytes + total > MAX_BATCH_BYTES" in sender_text
    assert 'if mode not in {"preflight", "stage", "snapshot"}' in sender_text
    for fingerprint_field in (
        "value.st_mode",
        "value.st_uid",
        "value.st_gid",
        "value.st_dev",
        "value.st_ino",
        "value.st_nlink",
        "value.st_size",
        "value.st_mtime_ns",
        "value.st_ctime_ns",
    ):
        assert fingerprint_field in sender_text
    assert 'include_snapshot(b"D", relative_directory' in sender_text
    assert 'include_snapshot(b"F", relative' in sender_text
    assert "systemctl stop nginx.service" not in sender_text
    assert "systemctl restart nginx.service" not in sender_text
    test_sender_recovery_mode_behavior(sender_text)
    test_sender_condition_context_and_status_behavior(sender_text)

    require_exact(preflight, "Service.Type", "oneshot")
    require_exact(preflight, "Service.User", "root")
    require_exact(preflight, "Service.Group", "root")
    require_exact(preflight, "Service.UMask", "0077")
    require_exact(
        preflight,
        "Service.ExecStart",
        "/usr/sbin/nginx -t -q",
    )
    require_exact(preflight, "Service.TimeoutStartSec", "2min")
    require_exact(preflight, "Service.Restart", "no")
    require_exact(preflight, "Service.NoNewPrivileges", "true")
    require_exact(preflight, "Service.PrivateTmp", "true")
    require_exact(preflight, "Service.PrivateDevices", "true")
    require_exact(preflight, "Service.ProtectSystem", "strict")
    require_exact(preflight, "Service.ProtectHome", "true")
    require_exact(preflight, "Service.PrivateNetwork", "true")
    require_exact(
        preflight,
        "Service.ReadOnlyPaths",
        "/etc/nginx /etc/letsencrypt /var/www/html/shuzijun.com.cn",
    )
    require_exact(preflight, "Service.ReadWritePaths", "/var/log/nginx")
    require_exact(
        preflight,
        "Service.InaccessiblePaths",
        "-/root -/var/lib/shuzijun-sync -/var/backups",
    )
    require_exact(
        preflight,
        "Service.CapabilityBoundingSet",
        "CAP_DAC_OVERRIDE CAP_NET_BIND_SERVICE",
    )
    require_exact(preflight, "Service.AmbientCapabilities", "")
    assert not any(key.startswith("Unit.Condition") for key in preflight)
    for forbidden in ("/usr/bin/ssh", "/usr/bin/rsync", "/usr/local/bin/wp", "sync-to-backup"):
        assert forbidden not in preflight_text

    full_verify_sha256 = hashlib.sha256(FULL_VERIFY.read_bytes()).hexdigest()
    assert f"VERIFY_SHA256={full_verify_sha256}" in static_verify_text
    assert 'test "$(sha256sum "$VERIFY_FD" | awk' in static_verify_text
    assert '/usr/bin/python3 -I /proc/self/fd/8 "$VERIFY_FD" 8<<\'PY\'' in static_verify_text
    assert "/usr/bin/python3 -I -" not in static_verify_text
    assert 'source.count(needle) != 1' in static_verify_text
    assert 'source.replace(needle, replacement)' in static_verify_text
    assert "nginx -t >/dev/null" in static_verify_text
    assert "webroot-security: static contract passed" in static_verify_text
    assert STATIC_VERIFY.stat().st_mode & 0o777 == 0o755
    test_static_transform_behavior(static_verify_text)

    require_exact(timer, "Timer.OnCalendar", "*-*-* 03:30:00 Asia/Shanghai")
    require_exact(timer, "Timer.RandomizedDelaySec", "10min")
    require_exact(timer, "Timer.AccuracySec", "1min")
    require_exact(timer, "Timer.Persistent", "true")
    require_exact(timer, "Timer.Unit", "shuzijun-sync.service")
    require_exact(timer, "Install.WantedBy", "timers.target")
    assert "OnUnitActiveSec=" not in timer_text
    assert "OnBootSec=" not in timer_text

    require_exact(fpm_guard, "Service.Type", "notify")
    require_exact(fpm_guard, "Service.NotifyAccess", "all")
    require_exact(fpm_guard, "Service.RemainAfterExit", "no")
    require_exact(fpm_guard, "Service.User", "root")
    require_exact(fpm_guard, "Service.Group", "root")
    require_exact(fpm_guard, "Service.UMask", "0077")
    require_exact(
        fpm_guard,
        "Service.ExecStart",
        "/usr/local/sbin/apply-shuzijun-sync --guard-watch "
        "/var/lib/shuzijun-sync/state/fpm-activation-guard.lease "
        "/var/lib/shuzijun-sync/state/fpm-activation-guard-v4.armed "
        "/var/lib/shuzijun-sync/state/fpm-activation-guard-v4.committed",
    )
    require_exact(
        fpm_guard,
        "Service.ExecStopPost",
        "/usr/local/sbin/apply-shuzijun-sync --guard-finalize "
        "/var/lib/shuzijun-sync/state/fpm-activation-guard-v4.committed",
    )
    require_exact(fpm_guard, "Service.Restart", "on-failure")
    require_exact(fpm_guard, "Service.RestartSec", "1s")
    require_exact(fpm_guard, "Service.RestartPreventExitStatus", "77")
    require_exact(fpm_guard, "Service.RuntimeMaxSec", "2min")
    require_exact(fpm_guard, "Unit.StartLimitIntervalSec", "10min")
    require_exact(fpm_guard, "Unit.StartLimitBurst", "3")
    require_exact(fpm_guard, "Service.KillMode", "control-group")
    require_exact(fpm_guard, "Service.NoNewPrivileges", "true")
    require_exact(fpm_guard, "Service.ProtectSystem", "strict")
    require_exact(fpm_guard, "Service.ProtectHome", "true")
    require_exact(
        fpm_guard, "Service.ReadWritePaths", "/var/lib/shuzijun-sync/state"
    )
    require_exact(
        fpm_guard,
        "Service.ReadOnlyPaths",
        "/var/www/html/shuzijun.com.cn/wp-content/uploads",
    )
    require_exact(fpm_guard, "Service.InaccessiblePaths", "-/root -/var/backups")
    require_exact(fpm_guard, "Service.RestrictAddressFamilies", "AF_UNIX")
    require_exact(fpm_guard, "Service.CapabilityBoundingSet", "")
    require_exact(fpm_guard, "Service.AmbientCapabilities", "")
    require_exact(fpm_guard, "Unit.Before", "php8.3-fpm.service")
    require_exact(fpm_guard, "Install.RequiredBy", "php8.3-fpm.service")
    assert "systemctl" not in fpm_guard_text, (
        "the unit must call only the fixed receiver mode, which owns exact isolation"
    )

    for forbidden in (
        "Environment=",
        "EnvironmentFile=",
        "ExecStart=/bin/sh",
        "ExecStart=/bin/bash",
        "Restart=always",
    ):
        assert forbidden not in service_text

    claim_install = readme_text.index("/var/lib/shuzijun-sync/incoming")
    accepted_state = readme_text.index(
        "/var/lib/shuzijun-sync/state/highest-accepted-generation", claim_install
    )
    signer_install = readme_text.index(
        "install -o root -g root -m 0644 <reviewed-allowed-signers-file>"
    )
    receiver_install = readme_text.index(
        "install -o root -g root -m 0755 Server/operations/apply-shuzijun-sync"
    )
    standby_full_verify_install = readme_text.index(
        "install -o root -g root -m 0755 Server/operations/verify-webroot-security",
        signer_install,
    )
    standby_deployer_install = readme_text.index(
        "install -o root -g root -m 0755 Server/operations/deploy-app-content-release",
        standby_full_verify_install,
    )
    standby_seed_install = readme_text.index(
        "install -o root -g root -m 0755 Server/operations/seed-standby-app-content-release",
        standby_deployer_install,
    )
    guard_install = readme_text.index(
        "install -o root -g root -m 0644 Server/operations/shuzijun-sync-fpm-guard.service",
        standby_seed_install,
    )
    gate_install = readme_text.index(
        "install -o root -g root -m 0755 Server/operations/shuzijun-sync-ssh-gate",
        receiver_install,
    )
    sudoers_install = readme_text.index(
        "Server/operations/shuzijun-sync-transport.sudoers", gate_install
    )
    sshd_install = readme_text.index(
        "Server/operations/shuzijun-sync-transport.sshd", sudoers_install
    )
    receiver_attestation = readme_text.index(
        "sha256sum /usr/local/sbin/apply-shuzijun-sync", sshd_install
    )
    protocol_probe = readme_text.index(
        "/usr/local/sbin/apply-shuzijun-sync --protocol", receiver_attestation
    )
    sender_install = readme_text.index(
        "install -o root -g root -m 0755 Server/operations/sync-to-backup"
    )
    issued_state = readme_text.index(
        "/var/lib/shuzijun-sync/highest-issued-generation", protocol_probe
    )
    timer_enable = readme_text.index("systemctl enable shuzijun-sync.timer")
    assert claim_install < accepted_state < signer_install < standby_full_verify_install
    assert standby_full_verify_install < standby_deployer_install < standby_seed_install
    assert standby_seed_install < guard_install < receiver_install
    assert receiver_install < gate_install < sudoers_install < sshd_install
    assert sshd_install < receiver_attestation < protocol_probe < issued_state
    assert issued_state < sender_install < timer_enable
    assert "install -o root -g root -m 0755 Server/operations/verify-shuzijun-sync-source" in readme_text
    assert "Server/operations/shuzijun-sync-preflight.service" in readme_text
    assert "systemctl start shuzijun-sync.service" in readme_text
    assert "hardened foreground generation 7" in readme_text
    assert "failure after acceptance deliberately leaves that counter advanced" in readme_text
    assert "this release's four-way `=7`" in readme_text
    assert "highest-issued-generation)\" = 7" in readme_text
    assert "highest-accepted-generation)\" = 7" in readme_text
    assert "incremental sync completed generation=7$" in readme_text
    assert "sync applied; generation=7 backup=" in readme_text
    assert "-p Type --value)\" = notify" in readme_text
    assert "-p NotifyAccess --value)\" = all" in readme_text
    assert "-p RemainAfterExit --value)\" = no" in readme_text
    assert "-p RuntimeMaxUSec --value)\" = 2min" in readme_text
    assert "-p RequiredBy --value" in readme_text
    assert "-p ActiveState --value)\" = inactive" in readme_text
    assert "-p SubState --value)\" = dead" in readme_text
    assert "boot-like/no-lease with no commit" in readme_text
    assert "exit 77" in readme_text
    assert "three starts per ten-minute window" in readme_text
    assert "fourth rapid FPM restart fail closed" in readme_text
    assert "systemctl reset-failed shuzijun-sync-fpm-guard.service" in readme_text
    assert "sync -f /etc/systemd/system" in readme_text
    assert "two-minute runtime ceiling" in readme_text
    assert "ExecStopPost" in readme_text
    assert "does not deadlock" in readme_text
    assert "TimeoutStopSec=1min" in readme_text
    assert "TERM and SIGKILL" in readme_text
    generation7_gate = readme_text.index("# STOP: do not create or enable the timer")
    timer_enable = readme_text.index("systemctl enable shuzijun-sync.timer")
    assert generation7_gate < timer_enable
    assert (
        "/usr/bin/flock -n /run/shuzijun-sync.lock \\\n  /usr/local/sbin/sync-to-backup"
        not in readme_text
    )
    assert "never call `sync-to-backup` directly" in readme_text
    assert "not systemd `Condition*`" in readme_text
    assert "private network namespace" in readme_text
    assert "eight-hour deadline" in readme_text
    assert "does not reuse a consumed generation" in readme_text
    assert "COPYFILE_DISABLE=1" in readme_text
    assert "`._*` AppleDouble" in readme_text
    assert "cleanup trap before validating" in readme_text
    assert "systemctl enable --now shuzijun-sync.timer" not in readme_text
    assert "stamp-shuzijun-sync.timer" in readme_text
    assert "os.O_EXCL" in readme_text
    assert "os.O_NOFOLLOW" in readme_text
    assert "os.fsync(descriptor)" in readme_text
    assert "os.fsync(directory)" in readme_text
    assert "03:30--03:41" in readme_text
    assert not any(path.name.startswith("._") for path in SERVICE.parent.iterdir())
    for required_doc in (
        "/run/shuzijun-sync/sync.lock",
        "systemctl stop shuzijun-sync.timer",
        "systemctl is-active --quiet shuzijun-sync.service",
        "systemd-analyze verify",
        "03:30",
        "Persistent=true",
        "/etc/shuzijun/sync-signers",
        "shuzijun-sync-receiver-v4-transactional-uploads",
        "canonical",
        "shuzijun-sync-transport",
        "visudo -cf",
        "sshd -t",
        "forcecommand /usr/local/sbin/shuzijun-sync-ssh-gate",
        "restrict",
        "NOPASSWD: ALL",
        "strictly above",
        "never reset, delete",
        "database plaintext",
    ):
        assert required_doc in readme_text

    print("sync-scheduler-contract-test: passed")


if __name__ == "__main__":
    main()
