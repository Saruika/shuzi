from pathlib import Path
import os
import runpy
import stat
import tempfile
from types import SimpleNamespace
from unittest import mock


SCRIPT = Path("Server/operations/shuzijun-internal-health")
SERVICE = Path("Server/operations/shuzijun-internal-health.service")
TIMER = Path("Server/operations/shuzijun-internal-health.timer")
SYNC_APPLIER = Path("Server/operations/apply-shuzijun-sync")


def main() -> None:
    source = SCRIPT.read_text(encoding="utf-8")
    service = SERVICE.read_text(encoding="utf-8")
    timer = TIMER.read_text(encoding="utf-8")
    sync_applier = SYNC_APPLIER.read_text(encoding="utf-8")
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
    assert 'PRIVATE_LOG_DIR = pathlib.Path("/var/lib/shuzijun-logs")' in source
    assert 'PRIVATE_LOG_DIR / "sync-authority.log"' in source
    assert 'PRIVATE_LOG_DIR / "sync-standby.log"' in source
    assert 'PRIVATE_LOG_DIR / "snapshot.log"' in source
    assert '"/var/log/' not in source
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
    assert "standby_sync_commit_generation_missing_or_invalid" in source
    assert "standby_sync_generation_mismatch_commit" in source
    assert "authority_sync_generation_missing_or_invalid" in source
    assert "sync_log_generation_missing_or_invalid" in source
    assert "authority_sync_generation_behind_completed_log" in source
    assert "standby_sync_generation_mismatch_applied_log" in source
    assert '"/var/lib/shuzijun-sync/highest-issued-generation"' in source
    assert '"/var/lib/shuzijun-sync/state/highest-accepted-generation"' in source
    assert '"/var/lib/shuzijun-sync/state/fpm-activation-guard-v4.committed"' in source
    assert '"/var/lib/shuzijun-sync/state/fpm-activation-guard.committed"' not in source
    assert "committed_generation = committed_generation_state(COMMITTED_GENERATION)" in source
    assert 'rb"(?:0|[1-9][0-9]{0,18})\\n"' in source
    assert "int(value[:-1]) < 2**63" in source
    assert "stat.S_IMODE(metadata.st_mode) & 0o022 == 0" in source
    assert "stat.S_IMODE(metadata.st_mode) == 0o600" in source
    assert "stat.S_IMODE(metadata.st_mode) == 0o700" in source
    assert "def secure_root_directory_chain(path):" in source
    assert "if not secure_root_directory_chain(item.parent):" in source
    stable_log_source = source[
        source.index("def stable_log_tail(") : source.index("def success_generation(")
    ]
    stable_generation_source = source[
        source.index("def stable_generation_state(") : source.index("def valid_generation_bytes(")
    ]
    log_summary_source = source[
        source.index("def log_summary(") : source.index("def success_generation(")
    ]
    assert log_summary_source.index("secure_root_directory_chain(item.parent)") < log_summary_source.index(
        "stable_log_tail(item)"
    )
    assert "item.exists()" not in stable_log_source
    assert "file_mtime(item)" not in stable_log_source
    assert "item.read_text" not in stable_log_source
    for stable_read_guard in (
        "O_DIRECTORY",
        "O_NOFOLLOW",
        "O_NONBLOCK",
        "os.pread",
        "before_fd.st_dev",
        "before_fd.st_ino",
        "value.st_nlink",
        "before_fd.st_size",
        "value.st_mtime_ns",
        "value.st_ctime_ns",
        "after_path.st_dev",
        "after_path.st_ino",
        "secure_root_directory_chain(item.parent)",
    ):
        assert stable_read_guard in stable_log_source
    for stable_generation_guard in (
        "O_DIRECTORY",
        "O_NOFOLLOW",
        "O_NONBLOCK",
        "os.pread",
        "secure_private_regular_file_metadata",
        "secure_private_state_directory_metadata",
        "before_fd.st_dev != parent_before_fd.st_dev",
        "metadata.st_nlink",
        "metadata.st_mtime_ns",
        "metadata.st_ctime_ns",
        "after_path",
        "secure_root_directory_chain(item.parent)",
    ):
        assert stable_generation_guard in stable_generation_source
    assert "item.exists()" not in stable_generation_source
    assert "item.read_bytes()" not in stable_generation_source
    assert "incremental sync completed" in source
    assert "signed uploads/database sync applied" in source
    assert "snapshot already exists today; skip" in source
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
    valid_generation_state = namespace["valid_generation_state"]
    success_generation = namespace["success_generation"]
    valid_failover = namespace["validated_failover_payload"]
    age_within = namespace["age_within"]
    sync_reasons = namespace["sync_operation_reasons"]
    cdn_ok = namespace["authority_cdn_ok"]
    secure_directory_chain = namespace["secure_root_directory_chain"]
    secure_directory = namespace["secure_root_directory"]
    secure_directory_metadata = namespace["secure_root_directory_metadata"]
    secure_file_metadata = namespace["secure_regular_file_metadata"]
    secure_private_file_metadata = namespace["secure_private_regular_file_metadata"]
    secure_private_log_directory_metadata = namespace[
        "secure_private_log_directory_metadata"
    ]
    secure_private_state_directory_metadata = namespace[
        "secure_private_state_directory_metadata"
    ]
    committed_generation_pattern = namespace["COMMITTED_GENERATION_PATTERN"]
    assert committed_generation_pattern == (
        rb"[1-9][0-9]{0,18} [0-9a-f]{64} [0-9a-f]{64}\n"
    )
    assert committed_generation_pattern.decode("ascii") in sync_applier
    assert '"fpm-activation-guard-v4.committed"' in sync_applier
    generation_state = namespace["generation_state"]
    committed_generation_state = namespace["committed_generation_state"]
    stable_log_tail = namespace["stable_log_tail"]
    log_summary = namespace["log_summary"]
    safe_directory = SimpleNamespace(st_mode=stat.S_IFDIR | 0o755, st_uid=0, st_gid=0)
    assert secure_directory_metadata(safe_directory)
    for unsafe_directory in (
        SimpleNamespace(st_mode=stat.S_IFREG | 0o755, st_uid=0, st_gid=0),
        SimpleNamespace(st_mode=stat.S_IFLNK | 0o777, st_uid=0, st_gid=0),
        SimpleNamespace(st_mode=stat.S_IFDIR | 0o755, st_uid=1, st_gid=0),
        SimpleNamespace(st_mode=stat.S_IFDIR | 0o755, st_uid=0, st_gid=1),
        SimpleNamespace(st_mode=stat.S_IFDIR | 0o775, st_uid=0, st_gid=0),
        SimpleNamespace(st_mode=stat.S_IFDIR | 0o757, st_uid=0, st_gid=0),
    ):
        assert not secure_directory_metadata(unsafe_directory)
    safe_file = SimpleNamespace(
        st_mode=stat.S_IFREG | 0o600,
        st_uid=0,
        st_nlink=1,
    )
    assert secure_file_metadata(safe_file)
    for unsafe_file in (
        SimpleNamespace(st_mode=stat.S_IFDIR | 0o600, st_uid=0, st_nlink=1),
        SimpleNamespace(st_mode=stat.S_IFLNK | 0o600, st_uid=0, st_nlink=1),
        SimpleNamespace(st_mode=stat.S_IFREG | 0o600, st_uid=1, st_nlink=1),
        SimpleNamespace(st_mode=stat.S_IFREG | 0o600, st_uid=0, st_nlink=2),
        SimpleNamespace(st_mode=stat.S_IFREG | 0o620, st_uid=0, st_nlink=1),
        SimpleNamespace(st_mode=stat.S_IFREG | 0o602, st_uid=0, st_nlink=1),
    ):
        assert not secure_file_metadata(unsafe_file)
    private_directory = SimpleNamespace(
        st_mode=stat.S_IFDIR | 0o700, st_uid=0, st_gid=0
    )
    assert secure_private_log_directory_metadata(private_directory)
    for unsafe_private_directory in (
        SimpleNamespace(st_mode=stat.S_IFDIR | 0o750, st_uid=0, st_gid=0),
        SimpleNamespace(st_mode=stat.S_IFDIR | 0o700, st_uid=1, st_gid=0),
        SimpleNamespace(st_mode=stat.S_IFDIR | 0o700, st_uid=0, st_gid=1),
        SimpleNamespace(st_mode=stat.S_IFREG | 0o700, st_uid=0, st_gid=0),
    ):
        assert not secure_private_log_directory_metadata(unsafe_private_directory)
    assert secure_private_state_directory_metadata(private_directory)
    for unsafe_private_state_directory in (
        SimpleNamespace(st_mode=stat.S_IFDIR | 0o750, st_uid=0, st_gid=0),
        SimpleNamespace(st_mode=stat.S_IFDIR | 0o700, st_uid=1, st_gid=0),
        SimpleNamespace(st_mode=stat.S_IFDIR | 0o700, st_uid=0, st_gid=1),
        SimpleNamespace(st_mode=stat.S_IFREG | 0o700, st_uid=0, st_gid=0),
    ):
        assert not secure_private_state_directory_metadata(
            unsafe_private_state_directory
        )
    private_file = SimpleNamespace(
        st_mode=stat.S_IFREG | 0o600, st_uid=0, st_gid=0, st_nlink=1
    )
    assert secure_private_file_metadata(private_file)
    for unsafe_private_file in (
        SimpleNamespace(st_mode=stat.S_IFREG | 0o640, st_uid=0, st_gid=0, st_nlink=1),
        SimpleNamespace(st_mode=stat.S_IFREG | 0o600, st_uid=1, st_gid=0, st_nlink=1),
        SimpleNamespace(st_mode=stat.S_IFREG | 0o600, st_uid=0, st_gid=1, st_nlink=1),
        SimpleNamespace(st_mode=stat.S_IFREG | 0o600, st_uid=0, st_gid=0, st_nlink=2),
        SimpleNamespace(st_mode=stat.S_IFLNK | 0o600, st_uid=0, st_gid=0, st_nlink=1),
    ):
        assert not secure_private_file_metadata(unsafe_private_file)
    assert secure_directory_chain("/")
    assert not secure_directory_chain("/tmp")
    with mock.patch.object(Path, "resolve", side_effect=RuntimeError("symlink loop")):
        assert not secure_directory("/")
    untrusted_log = log_summary(
        "/tmp/shuzijun-health-contract-must-not-be-read.log",
        26,
        ("success",),
    )
    assert untrusted_log == {
        "path": "/tmp/shuzijun-health-contract-must-not-be-read.log",
        "present": False,
        "trusted": False,
        "parent_trusted": False,
        "mtime": None,
        "recent": False,
        "success_marker": False,
        "generation": None,
        "incomplete": False,
        "recent_error": None,
    }
    with tempfile.TemporaryDirectory(prefix="sj-untrusted-log-") as temporary:
        forged_log = Path(temporary) / "snapshot.log"
        forged_log.write_text("created success generation=42\n", encoding="utf-8")
        with mock.patch.object(os, "open", side_effect=AssertionError("untrusted log was opened")):
            forged_summary = log_summary(str(forged_log), 36, ("created ",))
        assert forged_summary["present"] is False
        assert forged_summary["trusted"] is False
        assert forged_summary["parent_trusted"] is False
        assert forged_summary["success_marker"] is False
        assert forged_summary["generation"] is None
        globals_map = log_summary.__globals__
        with mock.patch.dict(
            globals_map,
            {
                "PRIVATE_LOG_DIR": forged_log.parent,
                "secure_root_directory_chain": lambda _path: True,
                "secure_private_log_directory_metadata": lambda _metadata: True,
                "secure_private_regular_file_metadata": lambda _metadata: True,
            },
        ):
            trusted_summary = log_summary(str(forged_log), 36, ("created ",))
        assert trusted_summary["present"] is True
        assert trusted_summary["trusted"] is True
        assert trusted_summary["parent_trusted"] is True
        assert trusted_summary["success_marker"] is True
        assert trusted_summary["generation"] == 42

        forged_log.write_text(
            "[2026-09-03] snapshot already exists today; skip\n",
            encoding="utf-8",
        )
        with mock.patch.dict(
            globals_map,
            {
                "PRIVATE_LOG_DIR": forged_log.parent,
                "secure_root_directory_chain": lambda _path: True,
                "secure_private_log_directory_metadata": lambda _metadata: True,
                "secure_private_regular_file_metadata": lambda _metadata: True,
            },
        ):
            skipped_snapshot = log_summary(
                str(forged_log),
                36,
                ("created ", "snapshot already exists today; skip"),
            )
        assert skipped_snapshot["trusted"] is True
        assert skipped_snapshot["success_marker"] is True
        assert skipped_snapshot["recent_error"] is False

        forged_log.write_bytes(
            b"created success generation=7\n" + b"x" * 30000
        )
        with mock.patch.dict(
            globals_map,
            {
                "secure_root_directory_chain": lambda _path: True,
                "secure_private_log_directory_metadata": lambda _metadata: True,
                "secure_private_regular_file_metadata": lambda _metadata: True,
            },
        ):
            tail_trusted, tail_present, tail, tail_mtime = stable_log_tail(forged_log)
        assert tail_trusted is True
        assert tail_present is True
        assert len(tail) == 24000
        assert "generation=7" not in tail
        assert isinstance(tail_mtime, float)

        real_os_close = os.close
        close_calls = 0

        def close_then_report_error(descriptor):
            nonlocal close_calls
            close_calls += 1
            real_os_close(descriptor)
            raise OSError("simulated close reporting error")

        with mock.patch.dict(
            globals_map,
            {
                "secure_root_directory_chain": lambda _path: True,
                "secure_private_log_directory_metadata": lambda _metadata: True,
                "secure_private_regular_file_metadata": lambda _metadata: True,
            },
        ), mock.patch.object(os, "close", side_effect=close_then_report_error):
            close_trusted, close_present, close_tail, close_mtime = stable_log_tail(
                forged_log
            )
        assert close_calls == 2
        assert close_trusted is True
        assert close_present is True
        assert len(close_tail) == 24000
        assert isinstance(close_mtime, float)

        forged_log.write_text("created success generation=43\n", encoding="utf-8")
        real_os_stat = os.stat
        child_stat_calls = 0

        def rotate_after_read(path, *args, **kwargs):
            nonlocal child_stat_calls
            if kwargs.get("dir_fd") is not None:
                child_stat_calls += 1
                if child_stat_calls == 2:
                    raise FileNotFoundError("simulated log rotation")
            return real_os_stat(path, *args, **kwargs)

        with mock.patch.dict(
            globals_map,
            {
                "PRIVATE_LOG_DIR": forged_log.parent,
                "secure_root_directory_chain": lambda _path: True,
                "secure_private_log_directory_metadata": lambda _metadata: True,
                "secure_private_regular_file_metadata": lambda _metadata: True,
            },
        ), mock.patch.object(os, "stat", side_effect=rotate_after_read):
            rotated_summary = log_summary(str(forged_log), 36, ("created ",))
        assert child_stat_calls == 2
        assert rotated_summary["present"] is True
        assert rotated_summary["trusted"] is False
        assert rotated_summary["parent_trusted"] is True
        assert rotated_summary["mtime"] is None
        assert rotated_summary["success_marker"] is False
        assert rotated_summary["generation"] is None
    with tempfile.TemporaryDirectory(prefix="sj-generation-state-") as temporary:
        state_path = Path(temporary) / "generation"
        state_path.write_bytes(b"42\n")
        generation_globals = generation_state.__globals__
        with mock.patch.dict(
            generation_globals,
            {
                "secure_root_directory_chain": lambda _path: True,
                "secure_private_state_directory_metadata": lambda _metadata: True,
                "secure_private_regular_file_metadata": lambda _metadata: True,
            },
        ):
            state = generation_state(state_path)
        assert state == {"present": True, "trusted": True, "valid": True, "value": 42}

        def metadata_on_other_device(metadata):
            fields = (
                "st_dev",
                "st_ino",
                "st_mode",
                "st_uid",
                "st_gid",
                "st_nlink",
                "st_size",
                "st_mtime_ns",
                "st_ctime_ns",
            )
            values = {field: getattr(metadata, field) for field in fields}
            values["st_dev"] += 1
            return SimpleNamespace(**values)

        real_fstat = os.fstat
        real_lstat = os.lstat

        def cross_device_fstat(descriptor):
            metadata = real_fstat(descriptor)
            return (
                metadata_on_other_device(metadata)
                if stat.S_ISDIR(metadata.st_mode)
                else metadata
            )

        def cross_device_lstat(path):
            metadata = real_lstat(path)
            return (
                metadata_on_other_device(metadata)
                if Path(path) == state_path.parent
                else metadata
            )

        with mock.patch.dict(
            generation_globals,
            {
                "secure_root_directory_chain": lambda _path: True,
                "secure_private_state_directory_metadata": lambda _metadata: True,
                "secure_private_regular_file_metadata": lambda _metadata: True,
            },
        ), mock.patch.object(os, "fstat", side_effect=cross_device_fstat), mock.patch.object(
            os, "lstat", side_effect=cross_device_lstat
        ):
            cross_device_state = generation_state(state_path)
        assert cross_device_state == {
            "present": True,
            "trusted": False,
            "valid": False,
            "value": None,
        }

        state_path.write_bytes(b"01\n")
        with mock.patch.dict(
            generation_globals,
            {
                "secure_root_directory_chain": lambda _path: True,
                "secure_private_state_directory_metadata": lambda _metadata: True,
                "secure_private_regular_file_metadata": lambda _metadata: True,
            },
        ):
            invalid_state = generation_state(state_path)
        assert invalid_state == {
            "present": True,
            "trusted": True,
            "valid": False,
            "value": None,
        }
        commit_path = Path(temporary) / "fpm-activation-guard-v4.committed"
        commit_path.write_bytes(b"42 " + b"a" * 64 + b" " + b"b" * 64 + b"\n")
        with mock.patch.dict(
            generation_globals,
            {
                "secure_root_directory_chain": lambda _path: True,
                "secure_private_state_directory_metadata": lambda _metadata: True,
                "secure_private_regular_file_metadata": lambda _metadata: True,
            },
        ):
            committed_state = committed_generation_state(commit_path)
        assert committed_state == {
            "present": True,
            "trusted": True,
            "valid": True,
            "value": 42,
        }
        for invalid_commit in (
            b"42\n",
            b"0 " + b"a" * 64 + b" " + b"b" * 64 + b"\n",
            b"9223372036854775808 " + b"a" * 64 + b" " + b"b" * 64 + b"\n",
            b"42 " + b"A" * 64 + b" " + b"b" * 64 + b"\n",
            b"42 " + b"a" * 64 + b" " + b"b" * 63 + b"\n",
        ):
            commit_path.write_bytes(invalid_commit)
            with mock.patch.dict(
                generation_globals,
                {
                    "secure_root_directory_chain": lambda _path: True,
                    "secure_private_state_directory_metadata": lambda _metadata: True,
                    "secure_private_regular_file_metadata": lambda _metadata: True,
                },
            ):
                invalid_committed_state = committed_generation_state(commit_path)
            assert invalid_committed_state == {
                "present": True,
                "trusted": True,
                "valid": False,
                "value": None,
            }
        commit_path.write_bytes(b"x" * 193)
        with mock.patch.dict(
            generation_globals,
            {
                "secure_root_directory_chain": lambda _path: True,
                "secure_private_state_directory_metadata": lambda _metadata: True,
                "secure_private_regular_file_metadata": lambda _metadata: True,
            },
        ):
            oversized_committed_state = committed_generation_state(commit_path)
        assert oversized_committed_state == {
            "present": True,
            "trusted": False,
            "valid": False,
            "value": None,
        }
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
    assert valid_generation_state(
        {"trusted": True, "valid": True, "value": 9223372036854775807}
    )
    for invalid_state in (
        None,
        {},
        {"trusted": False, "valid": True, "value": 42},
        {"trusted": True, "valid": False, "value": 42},
        {"trusted": True, "valid": True, "value": True},
        {"trusted": True, "valid": True, "value": -1},
        {"trusted": True, "valid": True, "value": 2**63},
    ):
        assert not valid_generation_state(invalid_state)
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
        "authority", authority_operations, good_log, {"trusted": True, "valid": True, "value": 42}
    ) == []
    assert sync_reasons(
        "authority", authority_operations, good_log, {"trusted": True, "valid": True, "value": 43}
    ) == []
    assert "authority_sync_generation_behind_completed_log" in sync_reasons(
        "authority", authority_operations, good_log, {"trusted": True, "valid": True, "value": 41}
    )
    assert "sync_log_generation_missing_or_invalid" in sync_reasons(
        "authority",
        authority_operations,
        dict(good_log, generation=None),
        {"trusted": True, "valid": True, "value": 42},
    )
    for bad_result in ("exit-code", "signal", "timeout", "unknown"):
        operations = dict(authority_operations, sync_service_result=bad_result)
        assert "sync_service_result_not_success" in sync_reasons(
            "authority", operations, good_log, {"trusted": True, "valid": True, "value": 42}
        )
    assert "authority_sync_generation_missing_or_invalid" in sync_reasons(
        "authority", authority_operations, good_log, {"trusted": False, "valid": False, "value": None}
    )
    assert "sync_last_success_untrusted_or_stale" in sync_reasons(
        "authority",
        authority_operations,
        dict(good_log, recent=False),
        {"trusted": True, "valid": True, "value": 42},
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
        {"trusted": True, "valid": True, "value": 42},
        good_failover,
        {"trusted": True, "valid": True, "value": 42},
    ) == []
    for mismatched_value in (0, 41, 43):
        assert "standby_sync_generation_mismatch_applied_log" in sync_reasons(
            "standby",
            standby_operations,
            good_log,
            {"trusted": True, "valid": True, "value": mismatched_value},
            good_failover,
            {"trusted": True, "valid": True, "value": mismatched_value},
        )
    assert "standby_sync_generation_mismatch_commit" in sync_reasons(
        "standby",
        standby_operations,
        good_log,
        {"trusted": True, "valid": True, "value": 42},
        good_failover,
        {"trusted": True, "valid": True, "value": 43},
    )
    assert "standby_sync_commit_generation_missing_or_invalid" in sync_reasons(
        "standby",
        standby_operations,
        good_log,
        {"trusted": True, "valid": True, "value": 42},
        good_failover,
        {"trusted": False, "valid": False, "value": None},
    )
    switched_failover = dict(good_failover, mode="backup")
    assert "standby_failover_mode_not_primary" in sync_reasons(
        "standby",
        standby_operations,
        good_log,
        {"trusted": True, "valid": True, "value": 42},
        switched_failover,
        {"trusted": True, "valid": True, "value": 42},
    )
    assert "standby_failover_timer_disabled" in sync_reasons(
        "standby",
        dict(standby_operations, failover_timer_enabled="disabled"),
        good_log,
        {"trusted": True, "valid": True, "value": 42},
        good_failover,
        {"trusted": True, "valid": True, "value": 42},
    )
    for bad_result in ("exit-code", "signal", "timeout", "unknown"):
        operations = dict(standby_operations, failover_service_result=bad_result)
        assert "standby_failover_service_result_not_success" in sync_reasons(
            "standby",
            operations,
            good_log,
            {"trusted": True, "valid": True, "value": 42},
            good_failover,
            {"trusted": True, "valid": True, "value": 42},
        )

    assert "Type=oneshot" in service
    assert "ExecStart=/usr/bin/python3 -I /usr/local/sbin/shuzijun-internal-health" in service
    assert "SuccessExitStatus=2" in service
    assert "TimeoutStartSec=4min" in service
    assert "ProtectSystem=strict" in service
    assert "ProtectHome=true" in service
    assert "ReadWritePaths=/var/lib/shuzijun-health" in service
    read_only_directives = [
        line for line in service.splitlines() if line.startswith("ReadOnlyPaths=")
    ]
    assert read_only_directives == [
        "ReadOnlyPaths=/var/lib/shuzijun-logs -/var/lib/shuzijun-sync"
    ]
    # Health-first deployment must still start before the optional sync state root
    # exists, while the deployer-created private-log root remains mandatory.
    assert read_only_directives[0].split("=", 1)[1].split() == [
        "/var/lib/shuzijun-logs",
        "-/var/lib/shuzijun-sync",
    ]
    assert "StateDirectory=shuzijun-health" in service
    assert "StateDirectoryMode=0700" in service
    assert "OnActiveSec=2min" in timer
    assert "OnBootSec=" not in timer
    assert "OnUnitActiveSec=5min" in timer
    assert "Persistent=true" in timer

    print("internal-health-contract-test: passed")


if __name__ == "__main__":
    main()
