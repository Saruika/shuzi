#!/usr/bin/env python3
"""Release contract for authority-only, completion-relative push polling."""

from __future__ import annotations

import hashlib
import re
import subprocess
from pathlib import Path


OPERATIONS = Path("Server/operations")
WORKER = OPERATIONS / "shuzijun-push-outbox-worker"
SERVICE = OPERATIONS / "shuzijun-push-outbox.service"
TIMER = OPERATIONS / "shuzijun-push-outbox.timer"
FPM_SYSTEMD = OPERATIONS / "shuzijun-push-fpm-systemd.conf"
FPM_POOL = OPERATIONS / "shuzijun-push-fpm-pool.conf"
DEPLOYER = OPERATIONS / "deploy-shuzijun-push-worker"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def position(text: str, fragment: str, start: int = 0) -> int:
    result = text.find(fragment, start)
    assert result >= 0, f"missing required fragment: {fragment}"
    return result


for required in (WORKER, SERVICE, TIMER, FPM_SYSTEMD, FPM_POOL, DEPLOYER):
    assert required.is_file(), f"missing push operations asset: {required}"

subprocess.run(["/bin/bash", "-n", str(WORKER)], check=True)
subprocess.run(["/bin/bash", "-n", str(DEPLOYER)], check=True)

worker = WORKER.read_text(encoding="utf-8")
service = SERVICE.read_text(encoding="utf-8")
timer = TIMER.read_text(encoding="utf-8")
fpm_systemd = FPM_SYSTEMD.read_text(encoding="utf-8")
fpm_pool = FPM_POOL.read_text(encoding="utf-8")
deployer = DEPLOYER.read_text(encoding="utf-8")
combined = "\n".join((worker, service, timer, fpm_systemd, fpm_pool, deployer))

# The service and PHP-FPM master consume one fixed root-only environment file.
environment_directive = "EnvironmentFile=/etc/shuzijun/push/apns.env"
assert environment_directive in service
assert environment_directive in fpm_systemd
assert "readonly APNS_ENV=$PRIVATE_ROOT/apns.env" in worker
assert "require_regular_file \"$APNS_ENV\" root root 600" in worker
assert "require_private_file \"$APNS_ENV\" root root 600" in deployer
assert 'require_dir "$PRIVATE_ROOT" root www-data 710' in deployer

# The plugin currently requires a mode-0400 file directly readable by www-data.
# A root-owned, non-writable parent plus immutable bit prevents that identity
# from replacing or modifying the service-readable files.
for path_name in ("APNS_PRIVATE_KEY", "APNS_DATA_KEY"):
    assert f'require_regular_file "${path_name}" www-data www-data 400' in worker
    assert f'require_private_file "${path_name}" www-data www-data 400' in deployer
    assert f'require_immutable "${path_name}"' in deployer
assert worker.count("require_immutable_private_file") >= 3
assert "/usr/bin/lsattr" in worker and "/usr/bin/lsattr" in deployer
immutable_check = worker[
    worker.index("require_immutable_private_file") : worker.index("[[ $EUID -eq 0")
]
assert "/usr/bin/lsattr -d" in immutable_check
assert "/usr/bin/setpriv" not in immutable_check
assert "root-managed deployment invariant" in immutable_check

expected_fpm_variables = {
    "YISHU_APNS_KEY_ID",
    "YISHU_APNS_TEAM_ID",
    "YISHU_APNS_PRIVATE_KEY_PATH",
    "YISHU_APNS_DATA_KEY_PATH",
}
actual_fpm_variables = set(re.findall(r"^env\[([A-Z0-9_]+)]", fpm_pool, re.MULTILINE))
assert actual_fpm_variables == expected_fpm_variables
assert "source " not in deployer
assert '. "$APNS_ENV"' not in deployer
assert "contains an unreviewed key" in deployer
assert "must contain exactly four assignments" in deployer

# systemd supplies a hard outer deadline and also independently rejects standby.
assert "ExecCondition=/usr/local/sbin/verify-shuzijun-account-authority-role authority" in service
assert "ExecStart=/usr/local/sbin/shuzijun-push-outbox-worker" in service
assert "TimeoutStartSec=45s" in service
assert "RuntimeDirectory=shuzijun-push-outbox" in service
assert "RuntimeDirectoryMode=0700" in service
assert "UMask=0077" in service
assert "NoNewPrivileges=true" in service
assert "ProtectSystem=strict" in service
assert "ProtectHome=true" in service
assert "PrivateDevices=true" in service
assert "CapabilityBoundingSet=CAP_SETUID CAP_SETGID CAP_DAC_READ_SEARCH" in service
assert "RestrictSUIDSGID=" not in service
assert re.search(r"^AmbientCapabilities=CAP_SETUID$", service, re.MULTILINE)
assert "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6" in service

# Reschedule after the oneshot finishes, not after it starts. A slow run must
# not consume its own next activation while the service is still active.
assert "Unit=shuzijun-push-outbox.service" in timer
assert "OnBootSec=75s" in timer
assert "OnUnitInactiveSec=5s" in timer
assert "OnUnitActiveSec=" not in timer
assert "AccuracySec=1s" in timer
assert "RandomizedDelaySec=0" in timer
assert "Persistent=false" in timer

# The worker holds the role-transition lock for the full run, verifies authority
# twice, and separately serializes outbox processing.
role_lock = position(worker, "exec 8<\"$ROLE_LOCK\"")
shared_lock = position(worker, "/usr/bin/flock -s -w 3 8")
first_role_check = position(worker, '"$ROLE_VERIFY" authority', shared_lock)
worker_lock = position(worker, "exec 9>>\"$WORKER_LOCK\"")
exclusive_lock = position(worker, "/usr/bin/flock -n 9")
second_role_check = position(worker, '"$ROLE_VERIFY" authority', first_role_check + 1)
timeout = position(worker, "/usr/bin/timeout --signal=TERM --kill-after=3s 40s")
hook = position(worker, 'cron event run "$SWEEP_HOOK"')
assert role_lock < shared_lock < first_role_check < worker_lock < exclusive_lock
assert exclusive_lock < second_role_check < timeout < hook
assert "readonly SWEEP_HOOK=yishu_sweep_push_outbox" in worker
assert "prior sweep still active" in worker
assert "authority transition busy" in worker
assert "--reuid=www-data" in worker and "--regid=www-data" in worker
assert "--bounding-set=-all" not in worker
assert ">/dev/null 2>&1" in worker
assert "set -x" not in worker
assert "printenv" not in worker and "env |" not in worker

# The deployer accepts only the reviewed node/role topology. The standby gets
# identical code/config but its timer is always disabled and inactive.
assert "primary:authority|backup:standby" in deployer
assert "ROLE_VERIFY_SHA=5fe67111642c53895e16afd0a9d6a341af881c3711736f9fe40a34b830e20a58" in worker
assert "ROLE_VERIFY_SHA=5fe67111642c53895e16afd0a9d6a341af881c3711736f9fe40a34b830e20a58" in deployer
for mode in ("--dry-run", "--install", "--status", "--uninstall"):
    assert mode in deployer
assert 'if [[ $ROLE == authority ]]; then' in deployer
assert 'enable --now shuzijun-push-outbox.timer' in deployer
assert 'disable --now shuzijun-push-outbox.timer' in deployer
assert "standby timer must remain disabled and inactive" in deployer
assert '"$ROLE_VERIFY" "$ROLE"' in deployer
assert "shuzijun-push-worker-deploy.lock" in deployer
assert 'exec 8<"$ROLE_LOCK"' in deployer
assert "/usr/bin/flock -s -w 3 8" in deployer
assert position(deployer, "acquire_operation_locks") < position(
    deployer, '"$ROLE_VERIFY" "$ROLE"'
)
assert "installed push-worker release is partial" in deployer
assert "ROLLBACK_NEW_INSTALL=1" in deployer
assert "incomplete initial install rolled back" in deployer
assert "remove_if_reviewed" in deployer
assert "incomplete uninstall rolled back" in deployer
assert "UNINSTALL_BACKUP=/run/shuzijun-push-worker-uninstall.$$" in deployer
assert "fixed deployer path required" in deployer
assert "APNs credential files were preserved" in deployer
assert "ROLLBACK_TIMER_UPGRADE=1" in deployer
assert "incomplete timer upgrade rolled back" in deployer
assert "previous timer preserved" in deployer
assert 'elif [[ "$INSTALLED_STATE" == reviewed ]]' in deployer
assert "reviewed release already installed" in deployer

# Each staged asset is content-addressed. A deployer can neither substitute nor
# silently overwrite an unreviewed installed target.
pins = {
    "WORKER_SHA": WORKER,
    "SERVICE_SHA": SERVICE,
    "TIMER_SHA": TIMER,
    "FPM_SYSTEMD_SHA": FPM_SYSTEMD,
    "FPM_POOL_SHA": FPM_POOL,
}
for variable, path in pins.items():
    match = re.search(rf"^readonly {variable}=([a-f0-9]{{64}})$", deployer, re.MULTILINE)
    assert match, f"missing content pin: {variable}"
    assert match.group(1) == digest(path), f"stale content pin: {variable}"
assert "installed target differs from the reviewed release" in deployer
assert "temporary=$target.build45.$$" in deployer
assert "expected=$4 temporary=$target" not in deployer
assert "readonly PREVIOUS_TIMER_SHA=7adf34cc6f17806842dca1acf35e554605a32ac3a7c17e795f4c7dbd80946bd8" in deployer
assert "installed timer differs from both reviewed releases" in deployer

upgrade = deployer[deployer.index("upgrade_reviewed_timer() {"):deployer.index("rollback_reviewed_timer() {")]
assert '"$SYSTEMD" stop shuzijun-push-outbox.timer' in upgrade
assert 'install_asset "$TIMER_SOURCE" "$TIMER_TARGET" 644 "$TIMER_SHA"' in upgrade
assert '"$SYSTEMD" restart' not in upgrade
assert "WORKER_SOURCE" not in upgrade and "SERVICE_SOURCE" not in upgrade
assert "FPM_SYSTEMD_SOURCE" not in upgrade and "FPM_POOL_SOURCE" not in upgrade
assert position(upgrade, '"$TIMER_UPGRADE_BACKUP/timer"') < position(upgrade, "ROLLBACK_TIMER_UPGRADE=1")
assert position(upgrade, "ROLLBACK_TIMER_UPGRADE=1") < position(upgrade, '"$SYSTEMD" stop')
assert position(upgrade, "timer_state_matches_role", position(upgrade, '"$SYSTEMD" daemon-reload')) < position(upgrade, "ROLLBACK_TIMER_UPGRADE=0")

# Release assets must not contain private-key material, actual secrets or shell
# tracing. Identifiers are supplied only by the root-only external env file.
private_key_marker = "-----BEGIN " + "PRIVATE KEY-----"
assert private_key_marker not in combined
assert "SecretKey=" not in combined and "SecretId=" not in combined
assert re.search(r"(?im)^\s*(password|token|secret)\s*=", combined) is None
assert re.search(r"(?m)^[A-Za-z0-9_-]{43}$", combined) is None
assert re.search(r"(?m)^YISHU_APNS_KEY_ID=[A-Z0-9]{10}$", combined) is None
assert re.search(r"(?m)^YISHU_APNS_TEAM_ID=[A-Z0-9]{10}$", combined) is None

subprocess.run(["python3", "Server/tests/push-timer-upgrade-contract-test.py"], check=True)
print("push outbox operations contract passed")
