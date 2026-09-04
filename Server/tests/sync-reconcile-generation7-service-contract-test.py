#!/usr/bin/env python3
"""Contract for the one-shot generation 7 receipt reconciliation unit."""

from pathlib import Path
import re
import shlex


RECOVERY_SERVICE = Path(
    "Server/operations/shuzijun-sync-reconcile-generation7.service"
)
SYNC_SERVICE = Path("Server/operations/shuzijun-sync.service")

GENERATION = "7"
EVIDENCE_SHA256 = (
    "9cd4dd8ea9c5873aa2cc930d0bf17386a554069ec52eb2deacfc8b8b168871d8"
)
RELEASE_ID = (
    "fcbf252a03f2b2daaa798cb63f6fd76c2219d345e3fe81b9b26120d2542b24d6"
)
INGEST_RECEIVER_SHA256 = (
    "0a28c89ef1ac427f6ac72e5268cb5aa0ed28169493aab64d05dd687a40e67e03"
)


def directives(path: Path) -> dict[str, list[str]]:
    result: dict[str, list[str]] = {}
    section = ""
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            assert section in {"Unit", "Service"}, (
                f"unexpected section in {path}: {section}"
            )
            continue
        assert section and "=" in line, f"malformed directive in {path}: {line}"
        key, value = line.split("=", 1)
        assert key and key.strip() == key, f"malformed key in {path}: {key!r}"
        result.setdefault(f"{section}.{key}", []).append(value)
    return result


def require_exact(unit: dict[str, list[str]], key: str, value: str) -> None:
    assert unit.get(key) == [value], f"{key} must be exactly {value!r}"


def test_fixed_reconciliation_command() -> None:
    unit = directives(RECOVERY_SERVICE)
    command_values = unit.get("Service.ExecStart")
    assert command_values is not None and len(command_values) == 1
    command = shlex.split(command_values[0], posix=True)
    assert command == [
        "/usr/bin/flock",
        "-n",
        "/run/shuzijun-sync/sync.lock",
        "/usr/local/sbin/sync-to-backup",
        "--reconcile-legacy-v4",
        GENERATION,
        EVIDENCE_SHA256,
        RELEASE_ID,
        INGEST_RECEIVER_SHA256,
    ]
    assert all(re.fullmatch(r"[0-9a-f]{64}", value) for value in command[-3:])

    all_exec_values = [
        value
        for key, values in unit.items()
        if key.startswith("Service.Exec")
        for value in values
    ]
    sender_invocations = []
    for value in all_exec_values:
        arguments = shlex.split(value, posix=True)
        if arguments and (
            arguments[0] == "/usr/local/sbin/sync-to-backup"
            or (
                arguments[0] == "/usr/bin/flock"
                and "/usr/local/sbin/sync-to-backup" in arguments[1:]
            )
        ):
            sender_invocations.append(value)
    assert sender_invocations == command_values
    assert command[4] != "" and command[4] == "--reconcile-legacy-v4"


def test_preflight_and_hardening_match_normal_sync() -> None:
    recovery = directives(RECOVERY_SERVICE)
    normal = directives(SYNC_SERVICE)

    require_exact(
        recovery, "Unit.Requires", "shuzijun-sync-preflight.service"
    )
    require_exact(
        recovery,
        "Unit.After",
        "network-online.target mysql.service nginx.service "
        "shuzijun-sync-preflight.service",
    )
    require_exact(recovery, "Unit.Wants", "network-online.target")
    require_exact(
        recovery,
        "Unit.RequiresMountsFor",
        "/var/www/html/shuzijun.com.cn /var/lib/shuzijun-sync "
        "/var/lib/shuzijun-logs /run",
    )

    assert recovery.get("Service.ExecStartPre") == normal.get(
        "Service.ExecStartPre"
    )
    assert recovery["Service.ExecStartPre"] == [
        "/usr/bin/systemctl is-active --quiet mysql.service",
        "/usr/bin/systemctl is-active --quiet nginx.service",
        "/usr/bin/systemctl is-active --quiet php8.3-fpm.service",
        "/usr/bin/test -x /usr/local/sbin/sync-to-backup",
        "/usr/bin/test -x /usr/local/sbin/verify-shuzijun-sync-source",
        "/usr/bin/test -x /usr/local/sbin/verify-shuzijun-webroot-security",
        "/usr/bin/test -f /root/.ssh/shuzijun_sync_ed25519",
        "/usr/bin/test -f /var/lib/shuzijun-sync/highest-issued-generation",
    ]

    shared_service_directives = (
        "Type",
        "User",
        "Group",
        "UMask",
        "RuntimeDirectory",
        "RuntimeDirectoryMode",
        "RuntimeDirectoryPreserve",
        "TimeoutStartSec",
        "TimeoutStopSec",
        "KillMode",
        "Restart",
        "Nice",
        "IOSchedulingClass",
        "IOSchedulingPriority",
        "NoNewPrivileges",
        "PrivateTmp",
        "PrivateDevices",
        "ProtectSystem",
        "ProtectHome",
        "ReadWritePaths",
        "ReadOnlyPaths",
        "ProtectHostname",
        "ProtectClock",
        "ProtectKernelTunables",
        "ProtectKernelModules",
        "ProtectKernelLogs",
        "ProtectControlGroups",
        "RestrictSUIDSGID",
        "LockPersonality",
        "RestrictRealtime",
        "RestrictAddressFamilies",
        "CapabilityBoundingSet",
        "AmbientCapabilities",
        "SystemCallArchitectures",
    )
    for directive in shared_service_directives:
        key = f"Service.{directive}"
        assert recovery.get(key) == normal.get(key), f"hardening drift: {key}"


def test_unit_is_manual_and_cannot_fall_back_to_normal_sync() -> None:
    text = RECOVERY_SERVICE.read_text(encoding="utf-8")
    unit = directives(RECOVERY_SERVICE)
    assert "[Install]" not in text
    assert not any(key.startswith("Install.") for key in unit)
    assert "WantedBy=" not in text and "RequiredBy=" not in text
    assert "Service.RemainAfterExit" not in unit
    require_exact(unit, "Service.Type", "oneshot")
    require_exact(unit, "Service.Restart", "no")

    start = shlex.split(unit["Service.ExecStart"][0], posix=True)
    assert start[1:4] == [
        "-n",
        "/run/shuzijun-sync/sync.lock",
        "/usr/local/sbin/sync-to-backup",
    ]
    assert len(start) == 9
    assert start[4:] == [
        "--reconcile-legacy-v4",
        GENERATION,
        EVIDENCE_SHA256,
        RELEASE_ID,
        INGEST_RECEIVER_SHA256,
    ]


def main() -> None:
    test_fixed_reconciliation_command()
    test_preflight_and_hardening_match_normal_sync()
    test_unit_is_manual_and_cannot_fall_back_to_normal_sync()
    print("sync-reconcile-generation7-service-contract-test: passed")


if __name__ == "__main__":
    main()
