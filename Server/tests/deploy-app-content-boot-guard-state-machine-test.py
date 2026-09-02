#!/usr/bin/env python3
"""Executable contract for the deployer's persistent PHP-FPM boot guard.

This test intentionally uses two layers:

* the real shell guard functions run against a deterministic fake systemctl;
* a small deployment state machine injects failures at every security boundary.

It never needs root, systemd, a webroot, or network access.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
import re
import subprocess
import textwrap


ROOT = Path(__file__).resolve().parents[1]
DEPLOYER = ROOT / "operations" / "deploy-app-content-release"
SOURCE = DEPLOYER.read_text(encoding="utf-8")


def source_between(start: str, end: str) -> str:
    start_offset = SOURCE.index(f"{start}() {{")
    end_offset = SOURCE.index(f"{end}() {{", start_offset)
    return SOURCE[start_offset:end_offset]


GUARD_FUNCTIONS = "\n".join(
    (
        source_between("require_fpm_enabled_policy", "protect_fpm_from_incomplete_boot"),
        source_between("protect_fpm_from_incomplete_boot", "release_fpm_boot_guard"),
        source_between("release_fpm_boot_guard", "is_fpm_persistently_masked"),
        source_between("is_fpm_persistently_masked", "restore_code_backup"),
        source_between("isolate_failed_fpm", "handle_failure"),
    )
)


@dataclass(frozen=True)
class ShellResult:
    returncode: int
    state: str
    active: bool
    flag: int
    calls: tuple[str, ...]


def run_real_guard_functions(
    action: str,
    *,
    state: str = "enabled",
    active: bool = True,
    flag: int = 0,
    mask_mode: str = "ok",
    unmask_mode: str = "ok",
    stop_mode: str = "ok",
) -> ShellResult:
    """Run exact functions extracted from the deployer with fake systemctl."""

    prelude = textwrap.dedent(
        f"""
        set -Eeuo pipefail
        FPM_SERVICE=php8.3-fpm
        FPM_BOOT_GUARD_ACTIVE={flag}
        MOCK_STATE={state!r}
        MOCK_ACTIVE={1 if active else 0}
        MOCK_MASK_MODE={mask_mode!r}
        MOCK_UNMASK_MODE={unmask_mode!r}
        MOCK_STOP_MODE={stop_mode!r}
        CALLS=()

        fail() {{
            printf 'mock-fail: %s\n' "$1" >&2
            return 1
        }}

        systemctl() {{
            local operation=${{1-}}
            case "$operation" in
                is-enabled)
                    printf '%s\n' "$MOCK_STATE"
                    [[ "$MOCK_STATE" == enabled ]]
                    ;;
                mask)
                    CALLS+=(mask)
                    if [[ "$MOCK_MASK_MODE" == fail-before ]]; then
                        return 1
                    fi
                    MOCK_STATE=masked
                    [[ "$MOCK_MASK_MODE" != fail-after ]]
                    ;;
                unmask)
                    CALLS+=(unmask)
                    if [[ "$MOCK_UNMASK_MODE" == fail-before ]]; then
                        return 1
                    fi
                    MOCK_STATE=enabled
                    [[ "$MOCK_UNMASK_MODE" != fail-after ]]
                    ;;
                stop)
                    CALLS+=(stop)
                    if [[ "$MOCK_STOP_MODE" == fail-before ]]; then
                        return 1
                    fi
                    MOCK_ACTIVE=0
                    [[ "$MOCK_STOP_MODE" != fail-after ]]
                    ;;
                start)
                    CALLS+=(start)
                    [[ "$MOCK_STATE" == enabled ]] || return 1
                    MOCK_ACTIVE=1
                    ;;
                is-active)
                    [[ "$MOCK_ACTIVE" -eq 1 ]]
                    ;;
                *)
                    return 97
                    ;;
            esac
        }}

        report_state() {{
            local status=$?
            set +e
            local joined
            joined=$(IFS=,; printf '%s' "${{CALLS[*]-}}")
            printf 'BOOT_GUARD_RESULT|%s|%s|%s|%s|%s\n' \
                "$status" "$MOCK_STATE" "$MOCK_ACTIVE" \
                "$FPM_BOOT_GUARD_ACTIVE" "$joined"
            exit "$status"
        }}
        trap report_state EXIT
        """
    )
    completed = subprocess.run(
        ["bash", "-c", prelude + "\n" + GUARD_FUNCTIONS + "\n" + action + "\n"],
        check=False,
        text=True,
        capture_output=True,
    )
    match = re.search(
        r"^BOOT_GUARD_RESULT\|(\d+)\|([^|]+)\|([01])\|([01])\|(.*)$",
        completed.stdout,
        flags=re.MULTILINE,
    )
    assert match, (
        f"guard harness did not report state (rc={completed.returncode}): "
        f"stdout={completed.stdout!r} stderr={completed.stderr!r}"
    )
    calls = tuple(item for item in match.group(5).split(",") if item)
    return ShellResult(
        returncode=completed.returncode,
        state=match.group(2),
        active=match.group(3) == "1",
        flag=int(match.group(4)),
        calls=calls,
    )


class InjectedFailure(RuntimeError):
    pass


@dataclass
class DeploymentModel:
    """Fail-closed reference state machine for the shell orchestration."""

    unit_state: str = "enabled"
    active: bool = True
    guard_flag: int = 0
    code: str = "old"
    manifest: str | None = "old"
    backup_manifest: str | None = None
    code_mutated: bool = False
    rollback_ready: bool = False
    main_failure: str | None = None
    rollback_failure: str | None = None
    events: list[str] = field(default_factory=list)

    def checkpoint(self, name: str, *, rollback: bool = False) -> None:
        self.events.append(name)
        selected = self.rollback_failure if rollback else self.main_failure
        if selected == name:
            raise InjectedFailure(name)

    def protect(self, name: str, *, rollback: bool = False) -> None:
        assert self.unit_state == "enabled", (
            f"{name}: guard installation did not require exact enabled state"
        )
        self.checkpoint(name, rollback=rollback)
        self.unit_state = "masked"
        self.guard_flag = 1

    def release(self, name: str, *, rollback: bool = False) -> None:
        if self.guard_flag != 1:
            self.events.append(f"{name}.noop")
            return
        self.checkpoint(name, rollback=rollback)
        self.unit_state = "enabled"
        self.guard_flag = 0

    def stop(self, name: str, *, rollback: bool = False) -> None:
        self.checkpoint(name, rollback=rollback)
        self.active = False

    def start(self, name: str, *, rollback: bool = False) -> None:
        assert self.unit_state == "enabled", f"{name}: start attempted while masked"
        self.checkpoint(name, rollback=rollback)
        self.active = True

    def online_check(self, name: str, *, rollback: bool = False) -> None:
        assert self.active, f"{name}: online check ran with PHP-FPM inactive"
        assert self.unit_state == "masked", (
            f"{name}: online check ran without the persistent boot guard"
        )
        self.checkpoint(name, rollback=rollback)

    def isolate(self) -> None:
        # Match isolate_failed_fpm: actual systemd state wins over the flag.
        self.events.append("isolate.reconcile")
        if self.unit_state == "masked":
            self.guard_flag = 1
        else:
            self.protect("isolate.mask", rollback=True)
        self.active = False
        self.events.append("isolate.stop")
        assert self.unit_state == "masked" and not self.active

    def restore_and_verify(self) -> None:
        if self.code_mutated:
            if self.guard_flag != 1:
                self.protect("rollback.mask-before-stop", rollback=True)
            self.stop("rollback.stop", rollback=True)
            self.checkpoint("rollback.restore", rollback=True)
            self.code = "old"
            self.manifest = self.backup_manifest

        self.release("rollback.unmask-before-start", rollback=True)
        self.start("rollback.start", rollback=True)
        self.protect("rollback.mask-online", rollback=True)
        for check in (
            "rollback.verify",
            "rollback.nginx",
            "rollback.direct-php",
            "rollback.api",
        ):
            self.online_check(check, rollback=True)
        self.release("rollback.final-unmask", rollback=True)

    def handle_failure(self) -> None:
        try:
            self.restore_and_verify()
        except (AssertionError, InjectedFailure):
            self.isolate()

    def deploy(self) -> bool:
        assert self.unit_state == "enabled"
        assert self.active
        self.events.append("backup")
        self.backup_manifest = self.manifest
        self.rollback_ready = True
        try:
            self.protect("main.mask-initial")
            self.stop("main.stop")
            assert self.unit_state == "masked" and not self.active

            # The real installer sets CODE_MUTATED before its first write.
            self.code_mutated = True
            self.code = "partial"
            self.checkpoint("main.mutate")
            self.code = "new"
            self.checkpoint("main.payload-written-manifest-unwritten")
            self.manifest = "new"
            self.checkpoint("main.manifest-written")
            self.checkpoint("main.offline-verify")

            self.release("main.unmask-before-start")
            self.start("main.start")
            self.protect("main.mask-online")
            for check in (
                "main.verify",
                "main.nginx",
                "main.direct-php",
                "main.api",
            ):
                self.online_check(check)
            self.release("main.final-unmask")
            self.rollback_ready = False
            self.events.append("rollback.disarmed")
            return True
        except (AssertionError, InjectedFailure):
            if self.rollback_ready:
                self.handle_failure()
            return False


def assert_real_shell_guard_contract() -> None:
    normal = run_real_guard_functions(
        """
        protect_fpm_from_incomplete_boot
        systemctl stop "$FPM_SERVICE"
        [[ "$MOCK_STATE" == masked && "$MOCK_ACTIVE" -eq 0 ]]
        CALLS+=(mutate)
        release_fpm_boot_guard
        systemctl start "$FPM_SERVICE"
        protect_fpm_from_incomplete_boot
        [[ "$MOCK_STATE" == masked && "$MOCK_ACTIVE" -eq 1 ]]
        CALLS+=(online-accepted)
        release_fpm_boot_guard
        """
    )
    assert normal.returncode == 0
    assert normal.state == "enabled" and normal.active and normal.flag == 0
    assert normal.calls == (
        "mask",
        "stop",
        "mutate",
        "unmask",
        "start",
        "mask",
        "online-accepted",
        "unmask",
    )

    # A first guard may only be installed from the exact enabled state.
    for unsafe_state in ("disabled", "static", "indirect", "linked", "masked"):
        rejected = run_real_guard_functions(
            "protect_fpm_from_incomplete_boot", state=unsafe_state
        )
        assert rejected.returncode != 0
        assert rejected.state == unsafe_state
        assert "mask" not in rejected.calls

    # If mask writes state but reports failure, the in-memory flag must record
    # that rollback/isolation is required.
    partial_mask = run_real_guard_functions(
        "protect_fpm_from_incomplete_boot", mask_mode="fail-after"
    )
    assert partial_mask.returncode != 0
    assert partial_mask.state == "masked" and partial_mask.flag == 1

    # Reconciliation must use actual systemd state in both directions.
    actual_masked_flag_clear = run_real_guard_functions(
        "isolate_failed_fpm", state="masked", active=True, flag=0
    )
    assert actual_masked_flag_clear.returncode == 0
    assert actual_masked_flag_clear.state == "masked"
    assert not actual_masked_flag_clear.active
    assert actual_masked_flag_clear.flag == 1
    assert "mask" not in actual_masked_flag_clear.calls

    actual_enabled_flag_set = run_real_guard_functions(
        "isolate_failed_fpm", state="enabled", active=True, flag=1
    )
    assert actual_enabled_flag_set.returncode == 0
    assert actual_enabled_flag_set.state == "masked"
    assert not actual_enabled_flag_set.active
    assert actual_enabled_flag_set.flag == 1
    assert "mask" in actual_enabled_flag_set.calls


def assert_source_is_bound_to_state_machine() -> None:
    enabled_policy = source_between(
        "require_fpm_enabled_policy", "protect_fpm_from_incomplete_boot"
    )
    assert '[[ "$unit_state" == enabled ]]' in enabled_policy
    protect = source_between(
        "protect_fpm_from_incomplete_boot", "release_fpm_boot_guard"
    )
    assert "require_fpm_enabled_policy" in protect
    assert 'systemctl mask "$FPM_SERVICE"' in protect
    assert "FPM_BOOT_GUARD_ACTIVE=1" in protect

    isolation = source_between("isolate_failed_fpm", "handle_failure")
    assert isolation.count("is_fpm_persistently_masked") >= 2
    assert "protect_fpm_from_incomplete_boot" in isolation
    assert 'systemctl stop "$FPM_SERVICE"' in isolation

    main = SOURCE[SOURCE.index("create_code_backup\n") :]
    ordered_tokens = (
        "create_code_backup",
        "protect_fpm_from_incomplete_boot",
        'systemctl stop "$FPM_SERVICE"',
        "install_release_unit",
        "verify_live_release_hashes",
        "release_fpm_boot_guard",
        'systemctl start "$FPM_SERVICE"',
        "protect_fpm_from_incomplete_boot",
        "run_webroot_verifier",
        "nginx -t",
        "probe_direct_php_blocked",
        "probe_unauthorized_api",
        "release_fpm_boot_guard",
        "ROLLBACK_READY=0",
    )
    cursor = 0
    for token in ordered_tokens:
        next_offset = main.find(token, cursor)
        assert next_offset >= 0, f"missing ordered deployment transition: {token}"
        cursor = next_offset + len(token)

    install = source_between("install_release_unit", "verify_restored_release_matches_backup")
    payload = install.index(
        '"$BUNDLE/shuzijun-app-content.php" "$TARGET_DIR/shuzijun-app-content.php"'
    )
    manifest_commit = install.index("install_live_manifest_atomic", payload)
    assert payload < manifest_commit
    atomic_manifest = source_between("install_live_manifest_atomic", "install_release_unit")
    assert atomic_manifest.index('sync -f "$LIVE_MANIFEST_STAGE"') < atomic_manifest.index(
        'mv -T -- "$LIVE_MANIFEST_STAGE" "$LIVE_MANIFEST"'
    )

    handler = SOURCE[
        SOURCE.index("handle_failure() {") : SOURCE.index("trap 'handle_failure $?'")
    ]
    assert "restore_code_backup" in handler
    assert "probe_direct_php_blocked" in handler
    assert "probe_unauthorized_api" in handler
    assert "release_fpm_boot_guard" in handler
    assert "isolate_failed_fpm" in handler


def assert_fault_injection_contract() -> None:
    success = DeploymentModel()
    assert success.deploy()
    assert success.code == "new"
    assert success.manifest == "new"
    assert success.unit_state == "enabled" and success.active
    assert success.guard_flag == 0 and not success.rollback_ready
    assert success.events.index("main.mask-initial") < success.events.index("main.stop")
    assert success.events.index("main.stop") < success.events.index("main.mutate")
    assert success.events.index("main.start") < success.events.index("main.mask-online")
    assert success.events.index("main.api") < success.events.index("main.final-unmask")

    # Every main-path failure after the backup must restore the old release and
    # may only return it online after guarded rollback acceptance succeeds.
    for failure in (
        "main.mask-initial",
        "main.stop",
        "main.mutate",
        "main.payload-written-manifest-unwritten",
        "main.manifest-written",
        "main.offline-verify",
        "main.unmask-before-start",
        "main.start",
        "main.mask-online",
        "main.verify",
        "main.nginx",
        "main.direct-php",
        "main.api",
        "main.final-unmask",
    ):
        model = DeploymentModel(main_failure=failure)
        assert not model.deploy(), failure
        assert model.code == "old", failure
        assert model.manifest == "old", failure
        assert model.unit_state == "enabled" and model.active, failure
        assert model.guard_flag == 0, failure
        assert model.events.index("rollback.mask-online") < model.events.index(
            "rollback.verify"
        )
        assert model.events.index("rollback.api") < model.events.index(
            "rollback.final-unmask"
        )

    # Exercise both sides of the final atomic manifest commit explicitly. A
    # failure after payload writes but before the rename and a failure after
    # the rename both restore the prior manifest presence and exact value.
    for previous_manifest in ("old", None):
        before_commit = DeploymentModel(
            manifest=previous_manifest,
            main_failure="main.payload-written-manifest-unwritten",
        )
        assert not before_commit.deploy()
        assert before_commit.code == "old"
        assert before_commit.manifest == previous_manifest
        assert "main.manifest-written" not in before_commit.events

        after_commit = DeploymentModel(
            manifest=previous_manifest,
            main_failure="main.manifest-written",
        )
        assert not after_commit.deploy()
        assert after_commit.code == "old"
        assert after_commit.manifest == previous_manifest
        assert "main.manifest-written" in after_commit.events

    # An online rollback failure is never allowed to leave PHP-FPM running or
    # reboot-startable, regardless of which acceptance layer fails.
    for rollback_failure in (
        "rollback.verify",
        "rollback.nginx",
        "rollback.direct-php",
        "rollback.api",
        "rollback.final-unmask",
    ):
        model = DeploymentModel(
            main_failure="main.verify", rollback_failure=rollback_failure
        )
        assert not model.deploy(), rollback_failure
        assert model.code == "old", rollback_failure
        assert model.unit_state == "masked", rollback_failure
        assert not model.active, rollback_failure
        assert model.guard_flag == 1, rollback_failure
        assert "isolate.reconcile" in model.events
        assert model.events[-1] == "isolate.stop"

    # The fail-closed reconciler must distrust either stale in-memory value.
    stale_clear = DeploymentModel(unit_state="masked", active=True, guard_flag=0)
    stale_clear.isolate()
    assert stale_clear.unit_state == "masked" and not stale_clear.active
    assert stale_clear.guard_flag == 1
    assert "isolate.mask" not in stale_clear.events

    stale_set = DeploymentModel(unit_state="enabled", active=True, guard_flag=1)
    stale_set.isolate()
    assert stale_set.unit_state == "masked" and not stale_set.active
    assert stale_set.guard_flag == 1
    assert "isolate.mask" in stale_set.events


def main() -> None:
    assert_source_is_bound_to_state_machine()
    assert_real_shell_guard_contract()
    assert_fault_injection_contract()
    print("deploy-app-content-boot-guard-state-machine-test: passed")


if __name__ == "__main__":
    main()
