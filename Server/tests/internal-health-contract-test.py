from pathlib import Path
import runpy


SCRIPT = Path("Server/operations/shuzijun-internal-health")
SERVICE = Path("Server/operations/shuzijun-internal-health.service")
TIMER = Path("Server/operations/shuzijun-internal-health.timer")


def main() -> None:
    source = SCRIPT.read_text(encoding="utf-8")
    service = SERVICE.read_text(encoding="utf-8")
    timer = TIMER.read_text(encoding="utf-8")
    namespace = runpy.run_path(str(SCRIPT))

    assert source.startswith("#!/usr/bin/env python3\n")
    assert SCRIPT.stat().st_mode & 0o111
    assert 'ROLE_FILE = pathlib.Path("/etc/shuzijun/account-authority-role")' in source
    assert 'ROLE_VERIFIER = pathlib.Path("/usr/local/sbin/verify-shuzijun-account-authority-role")' in source
    assert "5fe67111642c53895e16afd0a9d6a341af881c3711736f9fe40a34b830e20a58" in source
    assert 'raw_role not in (b"authority\\n", b"standby\\n")' in source
    assert "unit_state('shuzijun-failover.timer', 'is-enabled') == 'enabled'" not in source
    assert 'legacy_role = {"authority": "primary", "standby": "backup"}' in source
    assert "SYNC_MAX_AGE_HOURS = 26" in source
    assert '"/var/log/wp-sync.log"' in source
    assert '"/var/log/shuzijun-sync-receiver.log"' in source
    assert '"/var/log/shuzijun-sync-launch.log"' not in source
    assert "sync_timer_missing_or_disabled" in source
    assert 'operations.get("sync_service_result") != "success"' in source
    assert "sync_service_result_not_success" in source
    assert 'operations["sync_service_result"] == "failed"' not in source
    assert "standby_failover_timer_disabled" in source
    assert "standby_failover_service_result_not_success" in source
    assert "standby_failover_mode_not_primary" in source
    assert "authority_forbidden_failover_timer_active" in source
    assert "standby_forbidden_sync_timer_active" in source
    assert "standby_forbidden_cdn_timer_active" in source
    assert "authority_cdn_timer_or_service_unhealthy" in source
    assert "standby_sync_generation_missing_or_invalid" in source
    assert "authority_sync_generation_missing_or_invalid" in source
    assert "sync_log_generation_missing_or_invalid" in source
    assert "authority_sync_generation_behind_completed_log" in source
    assert "standby_sync_generation_mismatch_applied_log" in source
    assert '"/var/lib/shuzijun-sync/highest-issued-generation"' in source
    assert '"/var/lib/shuzijun-sync/state/highest-accepted-generation"' in source
    assert 'rb"(?:0|[1-9][0-9]{0,18})\\n"' in source
    assert "int(value[:-1]) < 2**63" in source
    assert "stat.S_IMODE(metadata.st_mode) & 0o022 == 0" in source
    assert "incremental sync completed" in source
    assert "signed uploads/database sync applied" in source
    for forbidden in (
        '"sync-to-backup"',
        '"--ingest"',
        '["systemctl", "start"',
        '["systemctl", "restart"',
        '["systemctl", "enable"',
    ):
        assert forbidden not in source

    classify = namespace["classify_status"]
    valid_generation = namespace["valid_generation_bytes"]
    success_generation = namespace["success_generation"]
    valid_failover = namespace["validated_failover_payload"]
    age_within = namespace["age_within"]
    sync_reasons = namespace["sync_operation_reasons"]
    cdn_ok = namespace["authority_cdn_ok"]
    assert classify([], []) == ("healthy", 0)
    assert classify([], ["sync_timer_missing_or_disabled"]) == ("degraded", 2)
    assert classify(["authority_role_unverified"], []) == ("critical", 1)
    assert classify(["required_route_failed"], ["sync_stale"]) == ("critical", 1)
    healthy_cdn = {
        "cdn_publish_timer_active": "active",
        "cdn_publish_timer_enabled": "enabled",
        "cdn_publish_service_result": "success",
    }
    assert cdn_ok(healthy_cdn)
    for bad_result in ("exit-code", "signal", "timeout", "unknown"):
        assert not cdn_ok(dict(healthy_cdn, cdn_publish_service_result=bad_result))
    assert not cdn_ok(dict(healthy_cdn, cdn_publish_timer_active="inactive"))
    assert not cdn_ok(dict(healthy_cdn, cdn_publish_timer_enabled="disabled"))
    assert valid_generation(b"0\n")
    assert valid_generation(b"42\n")
    assert valid_generation(b"9223372036854775807\n")
    assert success_generation("[time] completed generation=42") == 42
    assert success_generation("[time] completed generation=0 backup=/safe") == 0
    assert success_generation("[time] completed") is None
    assert success_generation("[time] generation=01 completed") is None
    assert success_generation("generation=1 generation=2") is None
    assert success_generation("generation=9223372036854775808") is None
    fixed_now = 2_000_000_000
    assert age_within(fixed_now - 25 * 3600, 26, fixed_now)
    assert age_within(fixed_now - 26 * 3600, 26, fixed_now)
    assert not age_within(fixed_now - 27 * 3600, 26, fixed_now)
    assert not age_within(fixed_now + 1, 26, fixed_now)
    for invalid in (
        b"",
        b"00\n",
        b"01\n",
        b"-1\n",
        b"1",
        b"1\nextra",
        b"9223372036854775808\n",
    ):
        assert not valid_generation(invalid)

    valid_failover_input = {
        "mode": "primary",
        "consecutive_failures": 0,
        "last_primary": {"ok": True},
        "last_backup": {"ok": True},
        "last_public_path": {"ok": True},
    }
    assert valid_failover(valid_failover_input) == {
        "mode": "primary",
        "consecutive_failures": 0,
        "primary_ok": True,
        "backup_ok": True,
        "public_path_ok": True,
    }
    for invalid_failover in (
        [],
        {},
        dict(valid_failover_input, mode="unknown"),
        dict(valid_failover_input, consecutive_failures=None),
        dict(valid_failover_input, consecutive_failures=True),
        dict(valid_failover_input, last_primary="yes"),
        dict(valid_failover_input, last_backup={"ok": 1}),
        dict(valid_failover_input, last_public_path={}),
    ):
        assert valid_failover(invalid_failover) is None

    good_log = {
        "trusted": True,
        "recent": True,
        "success_marker": True,
        "generation": 42,
        "incomplete": False,
        "recent_error": False,
    }
    authority_operations = {
        "sync_timer_active": "active",
        "sync_timer_enabled": "enabled",
        "sync_service_result": "success",
        "failover_timer_active": "inactive",
        "failover_timer_enabled": "disabled",
    }
    assert sync_reasons(
        "authority", authority_operations, good_log, {"valid": True, "value": 42}
    ) == []
    assert sync_reasons(
        "authority", authority_operations, good_log, {"valid": True, "value": 43}
    ) == []
    assert "authority_sync_generation_behind_completed_log" in sync_reasons(
        "authority", authority_operations, good_log, {"valid": True, "value": 41}
    )
    assert "sync_log_generation_missing_or_invalid" in sync_reasons(
        "authority",
        authority_operations,
        dict(good_log, generation=None),
        {"valid": True, "value": 42},
    )
    for bad_result in ("exit-code", "signal", "timeout", "unknown"):
        operations = dict(authority_operations, sync_service_result=bad_result)
        assert "sync_service_result_not_success" in sync_reasons(
            "authority", operations, good_log, {"valid": True, "value": 42}
        )
    assert "authority_sync_generation_missing_or_invalid" in sync_reasons(
        "authority", authority_operations, good_log, {"valid": False, "value": None}
    )
    assert "sync_last_success_untrusted_or_stale" in sync_reasons(
        "authority",
        authority_operations,
        dict(good_log, recent=False),
        {"valid": True, "value": 42},
    )

    standby_operations = {
        "failover_timer_active": "active",
        "failover_timer_enabled": "enabled",
        "failover_service_result": "success",
        "sync_timer_active": "inactive",
        "sync_timer_enabled": "disabled",
        "cdn_publish_timer_active": "inactive",
        "cdn_publish_timer_enabled": "disabled",
    }
    good_failover = {
        "readable": True,
        "schema_valid": True,
        "recent": True,
        "mode": "primary",
        "primary_ok": True,
        "backup_ok": True,
        "public_path_ok": True,
        "consecutive_failures": 0,
    }
    assert sync_reasons(
        "standby",
        standby_operations,
        good_log,
        {"valid": True, "value": 42},
        good_failover,
    ) == []
    for mismatched_value in (0, 41, 43):
        assert "standby_sync_generation_mismatch_applied_log" in sync_reasons(
            "standby",
            standby_operations,
            good_log,
            {"valid": True, "value": mismatched_value},
            good_failover,
        )
    switched_failover = dict(good_failover, mode="backup")
    assert "standby_failover_mode_not_primary" in sync_reasons(
        "standby",
        standby_operations,
        good_log,
        {"valid": True, "value": 42},
        switched_failover,
    )
    assert "standby_failover_timer_disabled" in sync_reasons(
        "standby",
        dict(standby_operations, failover_timer_enabled="disabled"),
        good_log,
        {"valid": True, "value": 42},
        good_failover,
    )
    for bad_result in ("exit-code", "signal", "timeout", "unknown"):
        operations = dict(standby_operations, failover_service_result=bad_result)
        assert "standby_failover_service_result_not_success" in sync_reasons(
            "standby",
            operations,
            good_log,
            {"valid": True, "value": 42},
            good_failover,
        )

    assert "Type=oneshot" in service
    assert "ExecStart=/usr/bin/python3 -I /usr/local/sbin/shuzijun-internal-health" in service
    assert "SuccessExitStatus=2" in service
    assert "TimeoutStartSec=4min" in service
    assert "ProtectSystem=strict" in service
    assert "ProtectHome=true" in service
    assert "ReadWritePaths=/var/lib/shuzijun-health" in service
    assert "StateDirectory=shuzijun-health" in service
    assert "StateDirectoryMode=0700" in service
    assert "OnUnitActiveSec=5min" in timer
    assert "Persistent=true" in timer

    print("internal-health-contract-test: passed")


if __name__ == "__main__":
    main()
