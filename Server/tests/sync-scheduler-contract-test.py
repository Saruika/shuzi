#!/usr/bin/env python3
"""Static contract for the primary-node WordPress sync scheduler."""

from pathlib import Path


SERVICE = Path("Server/operations/shuzijun-sync.service")
TIMER = Path("Server/operations/shuzijun-sync.timer")
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


def main() -> None:
    assert SERVICE.is_file() and not SERVICE.is_symlink()
    assert TIMER.is_file() and not TIMER.is_symlink()
    service_text = SERVICE.read_text(encoding="utf-8")
    timer_text = TIMER.read_text(encoding="utf-8")
    readme_text = README.read_text(encoding="utf-8")
    service = directives(SERVICE)
    timer = directives(TIMER)

    require_exact(service, "Service.Type", "oneshot")
    require_exact(service, "Service.User", "root")
    require_exact(service, "Service.Group", "root")
    require_exact(service, "Service.UMask", "0077")
    require_exact(
        service,
        "Service.ExecStart",
        "/usr/bin/flock -n /run/shuzijun-sync.lock /usr/local/sbin/sync-to-backup",
    )
    require_exact(service, "Service.TimeoutStartSec", "45min")
    require_exact(service, "Service.TimeoutStopSec", "2min")
    require_exact(service, "Service.KillMode", "control-group")
    require_exact(service, "Service.Restart", "no")

    assert service.get("Service.ExecCondition") == [
        "/usr/bin/systemctl is-active --quiet mysql.service",
        "/usr/bin/systemctl is-active --quiet nginx.service",
        "/usr/bin/systemctl is-active --quiet php8.3-fpm.service",
    ]
    assert service.get("Unit.ConditionFileIsExecutable") == [
        "/usr/local/sbin/sync-to-backup",
        "/usr/local/sbin/verify-shuzijun-webroot-security",
    ]
    assert service.get("Unit.ConditionPathExists") == [
        "/root/.ssh/shuzijun_sync_ed25519",
        "/var/lib/shuzijun-sync/highest-issued-generation",
    ]
    require_exact(
        service,
        "Unit.RequiresMountsFor",
        "/var/www/html/shuzijun.com.cn /var/lib/shuzijun-sync /var/log /run",
    )

    for key, value in (
        ("Service.NoNewPrivileges", "true"),
        ("Service.PrivateTmp", "true"),
        ("Service.PrivateDevices", "true"),
        ("Service.ProtectSystem", "strict"),
        ("Service.ProtectHome", "read-only"),
        ("Service.ReadWritePaths", "/var/lib/shuzijun-sync /run /var/log"),
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

    require_exact(timer, "Timer.OnCalendar", "*-*-* 03:30:00 Asia/Shanghai")
    require_exact(timer, "Timer.RandomizedDelaySec", "10min")
    require_exact(timer, "Timer.AccuracySec", "1min")
    require_exact(timer, "Timer.Persistent", "true")
    require_exact(timer, "Timer.Unit", "shuzijun-sync.service")
    require_exact(timer, "Install.WantedBy", "timers.target")
    assert "OnUnitActiveSec=" not in timer_text
    assert "OnBootSec=" not in timer_text

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
    timer_enable = readme_text.index("systemctl enable --now shuzijun-sync.timer")
    assert claim_install < accepted_state < signer_install < receiver_install
    assert receiver_install < gate_install < sudoers_install < sshd_install
    assert sshd_install < receiver_attestation < protocol_probe < issued_state
    assert issued_state < sender_install < timer_enable
    for required_doc in (
        "/run/shuzijun-sync.lock",
        "systemctl stop shuzijun-sync.timer",
        "systemctl is-active --quiet shuzijun-sync.service",
        "systemd-analyze verify",
        "03:30",
        "Persistent=true",
        "/etc/shuzijun/sync-signers",
        "shuzijun-sync-receiver-v3-signed-uploads-only",
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
