import ast
import fcntl
import gzip
import hashlib
import json
import os
import pwd
import re
import signal
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path


RECEIVER = Path("Server/operations/apply-shuzijun-sync")
SENDER = Path("Server/operations/sync-to-backup")
VERIFIER = Path("Server/operations/verify-webroot-security")
SENSITIVE_DENY = Path("Server/nginx/shuzijun-sensitive-files-deny.conf")
LEGACY_IMAGES = Path("Server/nginx/shuzijun-legacy-images-alias.conf")
NGINX_ROUTING_SMOKE = Path("Server/tests/nginx-sensitive-routing-smoke.sh")
NGINX_README = Path("Server/nginx/README.md")
NGINX_CONTRACT = Path("Server/operations/verify-nginx-server-block-contract.py")
AUTHORITY_VERIFIER = Path("Server/operations/verify-account-authority-role.py")
SSH_GATE = Path("Server/operations/shuzijun-sync-ssh-gate")
SUDOERS = Path("Server/operations/shuzijun-sync-transport.sudoers")
SSHD_MATCH = Path("Server/operations/shuzijun-sync-transport.sshd")
SYNC_KNOWN_HOSTS = Path("Server/operations/shuzijun-sync-known-hosts")
FPM_GUARD_SERVICE = Path("Server/operations/shuzijun-sync-fpm-guard.service")


def heredoc_after(text: str, marker: str) -> str:
    marker_offset = text.index(marker)
    opener = text.index("<<'PY'", marker_offset)
    start = text.index("\n", opener) + 1
    end = text.index("\nPY\n", start)
    return text[start:end] + "\n"


def localize_root_contract(program: str) -> str:
    """Retain metadata checks while using the unprivileged test identity."""
    return program.replace(".st_uid != 0", ".st_uid != os.getuid()").replace(
        ".st_gid != 0", ".st_gid != os.getgid()"
    )


def run_python_program(program: str, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, "-I", "-c", program, *arguments],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def localize_linux_rename_noreplace(program: str) -> str:
    """Emulate renameat2(RENAME_NOREPLACE) for Darwin contract fixtures."""
    if sys.platform.startswith("linux"):
        return program
    preamble = r'''
import ctypes as _test_ctypes
import os as _test_os
class _TestRenameNoReplace:
    argtypes = None
    restype = None
    def __call__(self, source_fd, source, destination_fd, destination, flags):
        if flags != 1:
            return -1
        source_name = _test_os.fsdecode(source)
        destination_name = _test_os.fsdecode(destination)
        try:
            _test_os.stat(
                destination_name,
                dir_fd=None if destination_fd == -100 else destination_fd,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            pass
        else:
            return -1
        _test_os.rename(
            source_name,
            destination_name,
            src_dir_fd=None if source_fd == -100 else source_fd,
            dst_dir_fd=None if destination_fd == -100 else destination_fd,
        )
        return 0
class _TestLibC:
    renameat2 = _TestRenameNoReplace()
_test_ctypes.CDLL = lambda *_args, **_kwargs: _TestLibC()
'''
    return preamble + program


def shell_function(text: str, name: str) -> str:
    """Extract one top-level shell function that contains no nested function."""
    start = text.index(f"{name}() {{")
    end = text.index("\n}\n", start) + 3
    return text[start:end]


def test_bounded_database_decompression(receiver_text: str) -> None:
    program = localize_linux_rename_noreplace(localize_root_contract(
        heredoc_after(receiver_text, "prepare_database_sql() {")
    )).replace(
        "MAX_DATABASE_SQL_BYTES = 4 * 1024 * 1024 * 1024",
        "MAX_DATABASE_SQL_BYTES = 1024",
    ).replace(
        "MIN_FREE_RESERVE = 1024 * 1024 * 1024", "MIN_FREE_RESERVE = 0", 1
    )

    def claim(root: Path, payload: bytes) -> Path:
        root.mkdir(mode=0o700)
        source = root / "shuzijun-sync.sql.gz"
        source.write_bytes(payload)
        source.chmod(0o600)
        return root

    with tempfile.TemporaryDirectory(prefix="sync-database-gzip-test-") as raw:
        temp = Path(raw).resolve()
        valid = claim(temp / "valid", gzip.compress(b"SELECT 1;\n"))
        result = run_python_program(program, str(valid))
        assert result.returncode == 0, result.stderr
        sql = valid / "shuzijun-sync.sql"
        assert sql.read_bytes() == b"SELECT 1;\n"
        assert sql.stat().st_nlink == 1 and stat_mode(sql) == 0o600
        assert not list(valid.glob(".database-sql.*"))

        oversized = claim(temp / "oversized", gzip.compress(b"x" * 1025))
        result = run_python_program(program, str(oversized))
        assert result.returncode != 0
        assert not (oversized / "shuzijun-sync.sql").exists()
        assert not list(oversized.glob(".database-sql.*"))

        trailing = claim(temp / "trailing", gzip.compress(b"ok") + b"trailing")
        result = run_python_program(program, str(trailing))
        assert result.returncode != 0
        assert not (trailing / "shuzijun-sync.sql").exists()

        concatenated = claim(
            temp / "concatenated", gzip.compress(b"first") + gzip.compress(b"second")
        )
        result = run_python_program(program, str(concatenated))
        assert result.returncode != 0
        assert not (concatenated / "shuzijun-sync.sql").exists()

        corrupted_payload = bytearray(gzip.compress(b"crc-check"))
        corrupted_payload[-5] ^= 0xFF
        corrupted = claim(temp / "corrupted", bytes(corrupted_payload))
        result = run_python_program(program, str(corrupted))
        assert result.returncode != 0
        assert not (corrupted / "shuzijun-sync.sql").exists()

        linked = claim(temp / "linked", gzip.compress(b"ok"))
        external = temp / "external"
        external.write_text("unchanged", encoding="utf-8")
        (linked / "shuzijun-sync.sql").symlink_to(external)
        result = run_python_program(program, str(linked))
        assert result.returncode != 0
        assert external.read_text(encoding="utf-8") == "unchanged"


def stat_mode(path: Path) -> int:
    return path.stat().st_mode & 0o777


def test_backup_retention(receiver_text: str) -> None:
    prepare = localize_root_contract(
        heredoc_after(receiver_text, "prepare_backup_destination() {")
    ).replace("MIN_FREE_RESERVE = 1024 * 1024 * 1024", "MIN_FREE_RESERVE = 0")
    publish = localize_linux_rename_noreplace(localize_root_contract(
        heredoc_after(receiver_text, "publish_backup_destination() {")
    ))
    retire = localize_root_contract(
        heredoc_after(receiver_text, "retire_backup_history() {")
    )

    def write_manifest(directory: Path) -> None:
        payload = (
            f"{hashlib.sha256((directory / 'wordpress.sql.gz').read_bytes()).hexdigest()}"
            "  wordpress.sql.gz\n"
            f"{hashlib.sha256((directory / 'wp-config.php').read_bytes()).hexdigest()}"
            "  wp-config.php\n"
        ).encode("ascii")
        manifest = directory / "backup.sha256"
        manifest.write_bytes(payload)
        manifest.chmod(0o600)

    def completed(root: Path, stamp: str) -> Path:
        directory = root / f"shuzijun-sync-v1-{stamp}"
        directory.mkdir(mode=0o700)
        for name in ("wordpress.sql.gz", "wp-config.php"):
            child = directory / name
            child.write_bytes(b"x")
            child.chmod(0o600)
        write_manifest(directory)
        return directory

    def publish_candidate(
        root: Path, candidate: Path, stamp: str
    ) -> subprocess.CompletedProcess[str]:
        return run_python_program(
            publish,
            str(root),
            str(candidate),
            stamp,
            hashlib.sha256((candidate / "wordpress.sql.gz").read_bytes()).hexdigest(),
            hashlib.sha256((candidate / "wp-config.php").read_bytes()).hexdigest(),
        )

    with tempfile.TemporaryDirectory(prefix="sync-backup-retention-test-") as raw:
        root = Path(raw).resolve() / "backups"
        root.mkdir(mode=0o755)
        stamps = [f"202609{i:02d}-010101" for i in range(1, 9)]
        for stamp in stamps:
            completed(root, stamp)
        legacy = root / "pre-sync-20200101-000000"
        legacy.mkdir(mode=0o777)
        legacy_payload = legacy / "unmanaged-symlink"
        legacy_payload.symlink_to(root / "missing-legacy-target")
        interrupted = root / ".shuzijun-sync-v1-20260908-010101.incomplete.interrupt"
        interrupted.mkdir(mode=0o700)
        interrupted_temp = interrupted / ".wordpress-sql-gz.abcd1234"
        interrupted_temp.write_bytes(b"partial-gzip")
        interrupted_temp.chmod(0o600)
        result = run_python_program(prepare, str(root), "20260909-010101", "4096")
        assert result.returncode == 0, result.stderr
        candidate = Path(result.stdout.strip())
        remaining = sorted(
            path.name for path in root.glob("shuzijun-sync-v1-*") if path.is_dir()
        )
        assert remaining == [f"shuzijun-sync-v1-{stamp}" for stamp in stamps], (
            "preparing a candidate must not retire an existing restore point"
        )
        assert legacy.is_dir() and legacy_payload.is_symlink(), (
            "legacy pre-sync backups must be ignored and left byte-for-byte unmanaged"
        )
        assert not interrupted.exists(), (
            "an exact root-only interrupted archive tempfile must be safely recoverable"
        )
        assert candidate.parent == root and candidate.name.startswith(
            ".shuzijun-sync-v1-20260909-010101.incomplete."
        )
        for name in ("wordpress.sql.gz", "wp-config.php"):
            child = candidate / name
            child.write_bytes(b"x")
            child.chmod(0o600)
        write_manifest(candidate)
        published = publish_candidate(root, candidate, "20260909-010101")
        assert published.returncode == 0, published.stderr
        destination = Path(published.stdout.strip())
        assert destination.name == "shuzijun-sync-v1-20260909-010101"
        retired = run_python_program(retire, str(root), str(destination))
        assert retired.returncode == 0, retired.stderr
        completed_names = sorted(path.name for path in root.glob("shuzijun-sync-v1-*"))
        assert completed_names == [
            *[f"shuzijun-sync-v1-{stamp}" for stamp in stamps[2:]],
            "shuzijun-sync-v1-20260909-010101",
        ], "only a fully published new backup may trigger oldest-first pruning"

        unknown = root / ".shuzijun-sync-v1-20260910-000000.incomplete.unknown"
        unknown.mkdir(mode=0o700)
        unknown_child = unknown / "unexpected-file"
        unknown_child.write_bytes(b"never-delete")
        unknown_child.chmod(0o600)
        continued = run_python_program(prepare, str(root), "20260910-010100", "1")
        assert continued.returncode == 0, continued.stderr
        assert unknown.exists() and unknown_child.read_bytes() == b"never-delete"
        unknown_child.unlink()
        unknown.rmdir()

        malformed = root / "shuzijun-sync-v1-20260910-010101"
        malformed.mkdir(mode=0o700)
        target = root / "outside"
        target.write_bytes(b"do-not-delete")
        (malformed / "wordpress.sql.gz").symlink_to(target)
        for name in ("wp-config.php", "backup.sha256"):
            child = malformed / name
            child.write_bytes(b"x")
            child.chmod(0o600)
        continued = run_python_program(prepare, str(root), "20260911-010101", "1")
        assert continued.returncode == 0, continued.stderr
        assert malformed.exists() and target.read_bytes() == b"do-not-delete"

        (malformed / "wordpress.sql.gz").unlink()
        linked_target = root / "hardlink-target"
        linked_target.write_bytes(b"do-not-delete")
        linked_target.chmod(0o600)
        os.link(linked_target, malformed / "wordpress.sql.gz")
        hardlinked = run_python_program(prepare, str(root), "20260911-010102", "1")
        assert hardlinked.returncode == 0, hardlinked.stderr
        assert malformed.exists() and linked_target.stat().st_nlink == 2

    with tempfile.TemporaryDirectory(prefix="sync-backup-integrity-test-") as raw:
        root = Path(raw).resolve() / "backups"
        root.mkdir(mode=0o755)
        managed = [completed(root, f"202610{i:02d}-010101") for i in range(1, 9)]
        oldest = managed[0]
        tampered_manifest = managed[-1] / "backup.sha256"
        tampered_manifest.write_bytes(b"0" * 163)
        continued = run_python_program(prepare, str(root), "20261009-010101", "1")
        assert continued.returncode == 0, continued.stderr
        assert oldest.exists() and len(list(root.glob("shuzijun-sync-v1-*"))) == 8

        write_manifest(managed[-1])
        (managed[-1] / "wp-config.php").write_bytes(b"tampered")
        continued = run_python_program(prepare, str(root), "20261009-010102", "1")
        assert continued.returncode == 0, continued.stderr
        assert oldest.exists() and len(list(root.glob("shuzijun-sync-v1-*"))) == 8

    with tempfile.TemporaryDirectory(prefix="sync-backup-finalize-integrity-") as raw:
        root = Path(raw).resolve() / "backups"
        root.mkdir(mode=0o755)
        prepared = run_python_program(prepare, str(root), "20261101-010101", "1")
        assert prepared.returncode == 0, prepared.stderr
        candidate = Path(prepared.stdout.strip())
        for name in ("wordpress.sql.gz", "wp-config.php"):
            child = candidate / name
            child.write_bytes(b"x")
            child.chmod(0o600)
        manifest = candidate / "backup.sha256"
        manifest.write_bytes(b"0" * 163)
        manifest.chmod(0o600)
        rejected = publish_candidate(root, candidate, "20261101-010101")
        assert rejected.returncode != 0 and candidate.exists()
        assert not (root / "shuzijun-sync-v1-20261101-010101").exists()

        write_manifest(candidate)
        (candidate / "wordpress.sql.gz").write_bytes(b"tampered")
        rejected = publish_candidate(root, candidate, "20261101-010101")
        assert rejected.returncode != 0 and candidate.exists()
        assert not (root / "shuzijun-sync-v1-20261101-010101").exists()

    with tempfile.TemporaryDirectory(prefix="sync-backup-publish-failure-") as raw:
        root = Path(raw).resolve() / "backups"
        root.mkdir(mode=0o755)
        originals = [completed(root, f"202612{i:02d}-010101") for i in range(1, 8)]
        original_payloads = {
            path.name: {
                child.name: child.read_bytes() for child in path.iterdir()
            }
            for path in originals
        }
        prepared = run_python_program(prepare, str(root), "20261208-010101", "1")
        assert prepared.returncode == 0, prepared.stderr
        candidate = Path(prepared.stdout.strip())
        for name in ("wordpress.sql.gz", "wp-config.php"):
            child = candidate / name
            child.write_bytes(b"new")
            child.chmod(0o600)
        manifest = candidate / "backup.sha256"
        manifest.write_bytes(b"invalid\n")
        manifest.chmod(0o600)
        rejected = publish_candidate(root, candidate, "20261208-010101")
        assert rejected.returncode != 0
        assert sorted(path.name for path in root.glob("shuzijun-sync-v1-*")) == sorted(
            original_payloads
        )
        for name, children in original_payloads.items():
            assert {
                child.name: child.read_bytes() for child in (root / name).iterdir()
            } == children, "failed publication must preserve all seven restore points byte-for-byte"

    with tempfile.TemporaryDirectory(prefix="sync-backup-clock-rollback-") as raw:
        root = Path(raw).resolve() / "backups"
        root.mkdir(mode=0o755)
        old_stamps = [f"202701{i:02d}-010101" for i in range(1, 8)]
        for stamp in old_stamps:
            completed(root, stamp)
        new_stamp = "20260101-010101"
        prepared = run_python_program(prepare, str(root), new_stamp, "1")
        assert prepared.returncode == 0, prepared.stderr
        candidate = Path(prepared.stdout.strip())
        for name in ("wordpress.sql.gz", "wp-config.php"):
            child = candidate / name
            child.write_bytes(b"new")
            child.chmod(0o600)
        write_manifest(candidate)
        published = publish_candidate(root, candidate, new_stamp)
        assert published.returncode == 0, published.stderr
        finalized = run_python_program(
            retire, str(root), published.stdout.strip()
        )
        assert finalized.returncode == 0, finalized.stderr
        names = sorted(path.name for path in root.glob("shuzijun-sync-v1-*"))
        assert f"shuzijun-sync-v1-{new_stamp}" in names
        assert f"shuzijun-sync-v1-{old_stamps[0]}" not in names
        assert len(names) == 7

    with tempfile.TemporaryDirectory(prefix="sync-backup-retire-interrupt-") as raw:
        root = Path(raw).resolve() / "backups"
        root.mkdir(mode=0o755)
        originals = [completed(root, f"202702{i:02d}-010101") for i in range(1, 8)]
        prepared = run_python_program(prepare, str(root), "20270208-010101", "1")
        assert prepared.returncode == 0, prepared.stderr
        candidate = Path(prepared.stdout.strip())
        for name in ("wordpress.sql.gz", "wp-config.php"):
            child = candidate / name
            child.write_bytes(b"new")
            child.chmod(0o600)
        write_manifest(candidate)

        published = publish_candidate(root, candidate, "20270208-010101")
        assert published.returncode == 0, published.stderr

        retirement_call = "    shutil.rmtree(tombstone)\n"
        assert retire.count(retirement_call) == 1
        interrupted_finalize = retire.replace(
            retirement_call,
            "    (tombstone / 'backup.sha256').unlink()\n"
            "    raise RuntimeError('simulated kill during retirement')\n",
        )
        interrupted = run_python_program(
            interrupted_finalize, str(root), published.stdout.strip()
        )
        assert interrupted.returncode != 0
        completed_after_interrupt = sorted(root.glob("shuzijun-sync-v1-*"))
        assert len(completed_after_interrupt) == 7
        assert root / "shuzijun-sync-v1-20270208-010101" in completed_after_interrupt
        assert originals[0] not in completed_after_interrupt
        tombstones = list(root.glob(".shuzijun-sync-v1-*.retiring"))
        assert len(tombstones) == 1
        assert {child.name for child in tombstones[0].iterdir()} == {
            "wordpress.sql.gz",
            "wp-config.php",
        }

        recovered = run_python_program(prepare, str(root), "20270209-010101", "1")
        assert recovered.returncode == 0, recovered.stderr
        assert not list(root.glob(".shuzijun-sync-v1-*.retiring"))
        assert len(list(root.glob("shuzijun-sync-v1-*"))) == 7
        assert Path(recovered.stdout.strip()).is_dir()


def run_binary_python_program(
    program: str, *arguments: str, payload: bytes
) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [sys.executable, "-I", "-c", program, *arguments],
        input=payload,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def test_sender_database_streams(sender_text: str) -> None:
    bound = heredoc_after(sender_text, "bound_database_sql_stream() {").replace(
        "MAX_DATABASE_SQL_BYTES = 4 * 1024 * 1024 * 1024",
        "MAX_DATABASE_SQL_BYTES = 8",
    )
    valid = run_binary_python_program(bound, payload=b"12345678")
    assert valid.returncode == 0 and valid.stdout == b"12345678"
    assert run_binary_python_program(bound, payload=b"").returncode != 0
    assert run_binary_python_program(bound, payload=b"123456789").returncode != 0

    store = localize_linux_rename_noreplace(localize_root_contract(
        heredoc_after(sender_text, "store_staged_database() {")
    )).replace(
        "MAX_DATABASE_GZIP_BYTES = 8 * 1024 * 1024 * 1024",
        "MAX_DATABASE_GZIP_BYTES = 8",
    ).replace("MIN_FREE_RESERVE = 1024 * 1024 * 1024", "MIN_FREE_RESERVE = 0")
    with tempfile.TemporaryDirectory(prefix="sync-sender-database-test-") as raw:
        root = Path(raw).resolve() / "candidate"
        root.mkdir(mode=0o700)
        stored = run_binary_python_program(store, str(root), "0", payload=b"gzipdata")
        database = root / "shuzijun-sync.sql.gz"
        assert stored.returncode == 0, stored.stderr.decode()
        assert database.read_bytes() == b"gzipdata"
        assert stat_mode(database) == 0o600 and database.stat().st_nlink == 1
        assert not list(root.glob(".database-gzip.*"))

        duplicate = run_binary_python_program(store, str(root), "0", payload=b"new")
        assert duplicate.returncode != 0 and database.read_bytes() == b"gzipdata"

        oversize_root = Path(raw).resolve() / "oversize"
        oversize_root.mkdir(mode=0o700)
        oversized = run_binary_python_program(
            store, str(oversize_root), "0", payload=b"123456789"
        )
        assert oversized.returncode != 0
        assert not (oversize_root / "shuzijun-sync.sql.gz").exists()
        assert not list(oversize_root.glob(".database-gzip.*"))

        empty_root = Path(raw).resolve() / "empty"
        empty_root.mkdir(mode=0o700)
        empty = run_binary_python_program(store, str(empty_root), "0", payload=b"")
        assert empty.returncode != 0
        assert not (empty_root / "shuzijun-sync.sql.gz").exists()

        linked_root = Path(raw).resolve() / "linked"
        linked_root.mkdir(mode=0o700)
        external = Path(raw).resolve() / "external"
        external.write_bytes(b"unchanged")
        (linked_root / "shuzijun-sync.sql.gz").symlink_to(external)
        linked = run_binary_python_program(store, str(linked_root), "0", payload=b"valid")
        assert linked.returncode != 0 and external.read_bytes() == b"unchanged"


def test_receiver_database_backup_bounds(receiver_text: str) -> None:
    bound = heredoc_after(
        receiver_text, "bound_backup_database_sql_stream() {"
    ).replace(
        "MAX_DATABASE_SQL_BYTES = 4 * 1024 * 1024 * 1024",
        "MAX_DATABASE_SQL_BYTES = 8",
    )
    valid = run_binary_python_program(bound, payload=b"12345678")
    assert valid.returncode == 0 and valid.stdout == b"12345678"
    assert run_binary_python_program(bound, payload=b"").returncode != 0
    assert run_binary_python_program(bound, payload=b"123456789").returncode != 0

    prepare = localize_root_contract(
        heredoc_after(receiver_text, "prepare_backup_destination() {")
    ).replace(
        "MAX_DATABASE_LOGICAL_BYTES = 4 * 1024 * 1024 * 1024",
        "MAX_DATABASE_LOGICAL_BYTES = 8",
    ).replace(
        "MIN_FREE_RESERVE = 1024 * 1024 * 1024", "MIN_FREE_RESERVE = 0"
    ).replace(
        "MIN_BACKUP_BUDGET = 128 * 1024 * 1024", "MIN_BACKUP_BUDGET = 1"
    )
    with tempfile.TemporaryDirectory(prefix="sync-receiver-database-budget-") as raw:
        accepted_root = Path(raw).resolve() / "accepted"
        accepted_root.mkdir(mode=0o755)
        at_limit = run_python_program(prepare, str(accepted_root), "20260904-010101", "8")
        assert at_limit.returncode == 0, at_limit.stderr

        rejected_root = Path(raw).resolve() / "rejected"
        rejected_root.mkdir(mode=0o755)
        over_limit = run_python_program(
            prepare, str(rejected_root), "20260904-010102", "9"
        )
        assert over_limit.returncode != 0
        assert not list(rejected_root.iterdir()), (
            "a 4 GiB+1 logical estimate must be rejected before backup mutation"
        )


def test_sender_database_logical_query_deadline(sender_text: str) -> None:
    function = shell_function(sender_text, "read_database_logical_bytes")

    def invoke(script_body: str) -> tuple[subprocess.CompletedProcess[str], float]:
        with tempfile.TemporaryDirectory(prefix="sync-wp-query-deadline-") as raw:
            stub = Path(raw).resolve() / "wp"
            stub.write_text("#!/bin/sh\n" + script_body, encoding="utf-8")
            stub.chmod(0o755)
            timeout_stub = Path(raw).resolve() / "timeout"
            timeout_stub.write_text(
                "#!/usr/bin/env python3\n"
                "import os, signal, subprocess, sys\n"
                "command = sys.argv[4:]\n"
                "child = subprocess.Popen(command, start_new_session=True)\n"
                "try:\n"
                "    raise SystemExit(child.wait(timeout=1))\n"
                "except subprocess.TimeoutExpired:\n"
                "    os.killpg(child.pid, signal.SIGKILL)\n"
                "    child.wait()\n"
                "    raise SystemExit(124)\n",
                encoding="utf-8",
            )
            timeout_stub.chmod(0o755)
            localized = function.replace("--kill-after=5s 30s", "--kill-after=1s 1s")
            localized = localized.replace("/usr/bin/timeout", str(timeout_stub))
            localized = localized.replace("/usr/bin/wp", str(stub))
            started = time.monotonic()
            result = subprocess.run(
                ["/bin/bash", "-c", "set -euo pipefail\n" + localized + "\nread_database_logical_bytes"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=5,
                check=False,
            )
            return result, time.monotonic() - started

    valid, _ = invoke("printf '4294967296\\n'\n")
    assert valid.returncode == 0 and valid.stdout == "4294967296\n"
    for invalid_body in (
        "exit 0\n",
        "printf '1\\n2\\n'\n",
        "printf '042\\n'\n",
        "printf '4294967297\\n'\n",
        "printf '9999999999999999999\\n'\n",
        "printf '42\\n'; exit 7\n",
    ):
        invalid, _ = invoke(invalid_body)
        assert invalid.returncode != 0, (invalid_body, invalid.stdout, invalid.stderr)

    timed_out, elapsed = invoke("trap '' TERM\nprintf '42\\n'\nsleep 30\n")
    assert timed_out.returncode != 0 and elapsed < 4, (
        "plausible stdout followed by a hang must not survive its local deadline",
        timed_out.stdout,
        timed_out.stderr,
        elapsed,
    )


def test_fpm_guard_activation_is_constant_time(receiver_text: str) -> None:
    validator = shell_function(
        receiver_text, "validate_fpm_guard_commit_matches_accepted"
    )
    assert 'manage_uploads_transaction validate-activation "$accepted"' in validator
    assert "validate-commit" not in validator

    program = heredoc_after(receiver_text, "manage_uploads_transaction() {")
    branch_start = program.index('if action == "validate-activation":')
    branch_end = program.index("\nif action == ", branch_start + 1)
    activation_branch = program[branch_start:branch_end]
    for recursive_operation in (
        "validate_tree(",
        "hash_file(",
        "os.fwalk(",
        "rglob(",
        "iterdir(",
    ):
        assert recursive_operation not in activation_branch, (
            f"guard activation branch must remain O(1): {recursive_operation}"
        )
    manage_header = receiver_text[
        receiver_text.index("manage_uploads_transaction() {") :
        receiver_text.index(" 9<<'PY'", receiver_text.index("manage_uploads_transaction() {"))
    ]
    assert "inspect|active-generation|validate-activation|validate-stable-base|" in manage_header
    assert "deadline=5s" in manage_header and "kill_after=2s" in manage_header

    exchange_start = program.index('elif action == "exchange":')
    exchange_end = program.index("\nelif action == ", exchange_start + 1)
    exchange_branch = program[exchange_start:exchange_end]
    assert "validate_tree(" not in exchange_branch and "hash_file(" not in exchange_branch
    main_window_start = receiver_text.rindex("\nMUTATION_GUARD=1\n")
    main_window_end = receiver_text.index(
        '\ncommit_fpm_activation_guard "$GENERATION"', main_window_start
    )
    critical_window = receiver_text[main_window_start:main_window_end]
    for forbidden in (
        "prepare_backup_destination",
        "prepare_uploads_transaction",
        "retire_backup_history",
        "validate-commit",
        "validate-active",
        "verify_webroot_security",
    ):
        assert forbidden not in critical_window, (
            f"FPM isolation window must not enter unbounded/deep work: {forbidden}"
        )

    with tempfile.TemporaryDirectory(prefix="sync-guard-o1-shell-") as raw:
        invoked = Path(raw).resolve() / "invoked"
        harness = (
            "set -euo pipefail\n"
            + validator
            + "\nread_accepted_generation() { printf '7\\n'; }\n"
            + "manage_uploads_transaction() {\n"
            + "  printf '%s\\n' \"$1\" >> \"$INVOKED\"\n"
            + "  if [[ \"$1\" == validate-commit ]]; then sleep 5; return 1; fi\n"
            + "  [[ \"$1\" == validate-activation && \"$2\" == 7 ]] || return 1\n"
            + "  printf '7\\n'\n"
            + "}\n"
            + "read_fpm_guard_marker() { printf '%064d\\n' 0; }\n"
            + "FPM_GUARD_COMMIT=/unused\nINVOKED=$1\n"
            + "validate_fpm_guard_commit_matches_accepted\n"
        )
        started = time.monotonic()
        result = subprocess.run(
            ["/bin/bash", "-c", harness, "guard-o1", str(invoked)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=2,
            check=False,
        )
        elapsed = time.monotonic() - started
        assert result.returncode == 0 and elapsed < 1, result.stderr
        assert invoked.read_text(encoding="ascii") == "validate-activation\n"


def test_secure_sync_logs(receiver_text: str, sender_text: str) -> None:
    """Exercise append, parent-mode, symlink and hard-link log gates."""
    receiver_program = localize_root_contract(
        heredoc_after(receiver_text, "append_secure_log() {")
    )
    sender_program = localize_root_contract(
        heredoc_after(sender_text, "append_sync_authority_event() {")
    )

    with tempfile.TemporaryDirectory(prefix="sync-secure-log-test-") as raw:
        base = Path(raw).resolve()

        receiver_var = base / "receiver-var"
        receiver_lib = receiver_var / "lib"
        receiver_root = receiver_lib / "shuzijun-logs"
        for directory, mode in (
            (receiver_var, 0o755),
            (receiver_lib, 0o755),
            (receiver_root, 0o700),
        ):
            directory.mkdir(mode=mode)
            directory.chmod(mode)
        receiver_log = receiver_root / "sync-standby.log"
        localized_receiver = receiver_program.replace(
            'Path("/var/lib/shuzijun-logs")', f"Path({str(receiver_root)!r})"
        ).replace(
            'for parent in (Path("/var"), Path("/var/lib")):',
            "for parent in (root.parent.parent, root.parent):",
        )
        first = run_python_program(
            localized_receiver, str(receiver_root), str(receiver_log), "receiver-one"
        )
        assert first.returncode == 0, first.stderr
        second = run_python_program(
            localized_receiver, str(receiver_root), str(receiver_log), "receiver-two"
        )
        assert second.returncode == 0, second.stderr
        assert receiver_log.read_text(encoding="utf-8") == "receiver-one\nreceiver-two\n"
        assert stat_mode(receiver_log) == 0o600 and receiver_log.stat().st_nlink == 1

        receiver_log.unlink()
        outside = base / "outside-receiver"
        outside.write_text("unchanged", encoding="utf-8")
        receiver_log.symlink_to(outside)
        rejected = run_python_program(
            localized_receiver, str(receiver_root), str(receiver_log), "never"
        )
        assert rejected.returncode != 0 and outside.read_text(encoding="utf-8") == "unchanged"
        receiver_log.unlink()
        outside.chmod(0o600)
        os.link(outside, receiver_log)
        rejected = run_python_program(
            localized_receiver, str(receiver_root), str(receiver_log), "never"
        )
        assert rejected.returncode != 0 and outside.read_text(encoding="utf-8") == "unchanged"
        receiver_log.unlink()
        outside.unlink()
        receiver_log.write_text("unsafe\n", encoding="utf-8")
        receiver_log.chmod(0o666)
        assert run_python_program(
            localized_receiver, str(receiver_root), str(receiver_log), "never"
        ).returncode != 0
        receiver_log.unlink()
        receiver_root.chmod(0o755)
        assert run_python_program(
            localized_receiver, str(receiver_root), str(receiver_log), "never"
        ).returncode != 0

        sender_fs = base / "sender-root"
        sender_var = sender_fs / "var"
        sender_lib = sender_var / "lib"
        sender_root = sender_lib / "shuzijun-logs"
        for directory, mode in (
            (sender_fs, 0o700),
            (sender_var, 0o755),
            (sender_lib, 0o755),
            (sender_root, 0o700),
        ):
            directory.mkdir(mode=mode)
            directory.chmod(mode)
        sender_log = sender_root / "sync-authority.log"
        localized_sender = sender_program.replace(
            'Path("/var/lib/shuzijun-logs/sync-authority.log")',
            f"Path({str(sender_log)!r})",
        ).replace(
            'os.open("/", directory_flags)',
            f"os.open(Path({str(sender_fs)!r}), directory_flags)",
        ).replace(
            ".st_gid != os.getgid()", ".st_gid != EXPECTED_LOG.parent.stat().st_gid"
        )
        started = run_python_program(
            localized_sender, str(sender_log), "start", ""
        )
        assert started.returncode == 0, started.stderr
        completed = run_python_program(
            localized_sender, str(sender_log), "completion", "7"
        )
        assert completed.returncode == 0, completed.stderr
        sender_payload = sender_log.read_text(encoding="ascii")
        assert "incremental sync started" in sender_payload
        assert "incremental sync completed generation=7" in sender_payload
        assert stat_mode(sender_log) == 0o600 and sender_log.stat().st_nlink == 1

        sender_log.unlink()
        outside = base / "outside-sender"
        outside.write_text("unchanged", encoding="ascii")
        sender_log.symlink_to(outside)
        rejected = run_python_program(
            localized_sender, str(sender_log), "completion", "8"
        )
        assert rejected.returncode != 0 and outside.read_text(encoding="ascii") == "unchanged"
        sender_log.unlink()
        outside.chmod(0o600)
        os.link(outside, sender_log)
        assert run_python_program(
            localized_sender, str(sender_log), "completion", "8"
        ).returncode != 0


def test_ingest_receipt_exactness(sender_text: str) -> None:
    """The authenticated receiver acknowledgement is an exact byte contract."""
    start = sender_text.index("printf -v EXPECTED_INGEST_RECEIPT")
    end = sender_text.index(
        'test "$INGEST_RECEIPT" = "$EXPECTED_INGEST_RECEIPT"', start
    )
    end = sender_text.index("\n", end) + 1
    comparison = sender_text[start:end]
    receiver_hash = "a" * 64
    protocol = "shuzijun-sync-receiver-v4-transactional-uploads"
    line = (
        f"sync-applied generation=7 receiver-sha256={receiver_hash} "
        f"protocol={protocol} cache=flushed signed=true uploads-only=true\n"
    )

    def check(payload: str) -> int:
        harness = (
            "set -euo pipefail\n"
            "GENERATION=7\n"
            f"REMOTE_RECEIVER_SHA256={receiver_hash}\n"
            f"SYNC_PROTOCOL={protocol}\n"
            "INGEST_RECEIPT=$1\n"
            + comparison
        )
        return subprocess.run(
            ["/bin/bash", "-c", harness, "receipt-test", payload],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        ).returncode

    assert check(line + "\x1e") == 0
    for invalid in (
        line,
        line.rstrip("\n") + "\x1e",
        line + "extra\n\x1e",
        "prefix\n" + line + "\x1e",
        line[:-8] + "\x1e",
        line + "\x1e\x1e",
    ):
        assert check(invalid) != 0


def test_sender_upload_staging(sender_text: str) -> None:
    program = localize_root_contract(
        heredoc_after(sender_text, "audit_or_stage_uploads() {")
    )
    replacements = {
        "MAX_FILES = 100_000": "MAX_FILES = 4",
        "MAX_DIRECTORIES = 100_000": "MAX_DIRECTORIES = 4",
        "MAX_FILE_BYTES = 8 * 1024 * 1024 * 1024": "MAX_FILE_BYTES = 8",
        "MAX_BATCH_BYTES = 64 * 1024 * 1024 * 1024": "MAX_BATCH_BYTES = 16",
        "MAX_DATABASE_SQL_BYTES = 4 * 1024 * 1024 * 1024": "MAX_DATABASE_SQL_BYTES = 8",
        "MAX_DATABASE_GZIP_BYTES = 8 * 1024 * 1024 * 1024": "MAX_DATABASE_GZIP_BYTES = 8",
        "MIN_DATABASE_BUDGET = 128 * 1024 * 1024": "MIN_DATABASE_BUDGET = 1",
        "logical_bytes * 2 + 64 * 1024 * 1024": "logical_bytes * 2 + 1",
        "MIN_FREE_RESERVE = 1024 * 1024 * 1024": "MIN_FREE_RESERVE = 0",
    }
    for original, replacement in replacements.items():
        program = program.replace(original, replacement)

    def roots(base: Path) -> tuple[Path, Path]:
        candidate = base / "candidate"
        uploads = base / "uploads"
        candidate.mkdir(mode=0o700)
        uploads.mkdir(mode=0o700)
        return candidate, uploads

    with tempfile.TemporaryDirectory(prefix="sync-sender-upload-test-") as raw:
        base = Path(raw).resolve()
        candidate, uploads = roots(base)
        (uploads / "a.jpg").write_bytes(b"abc")
        (uploads / "b.jpg").write_bytes(b"def")
        preflight = run_python_program(program, "preflight", str(candidate), str(uploads), "1")
        assert preflight.returncode == 0, preflight.stderr
        database = candidate / "shuzijun-sync.sql.gz"
        database.write_bytes(b"db")
        database.chmod(0o600)
        staged = run_python_program(program, "stage", str(candidate), str(uploads), "1")
        assert staged.returncode == 0, staged.stderr
        copied = candidate / "wp-content" / "uploads"
        assert (copied / "a.jpg").read_bytes() == b"abc"
        assert (copied / "b.jpg").read_bytes() == b"def"
        assert stat_mode(copied / "a.jpg") == 0o600

    with tempfile.TemporaryDirectory(prefix="sync-sender-upload-limit-") as raw:
        base = Path(raw).resolve()
        candidate, uploads = roots(base)
        (uploads / "oversized.jpg").write_bytes(b"x" * 9)
        assert run_python_program(
            program, "preflight", str(candidate), str(uploads), "1"
        ).returncode != 0

    with tempfile.TemporaryDirectory(prefix="sync-sender-upload-count-") as raw:
        base = Path(raw).resolve()
        candidate, uploads = roots(base)
        for index in range(4):
            (uploads / f"{index}.jpg").write_bytes(b"x")
        assert run_python_program(
            program, "preflight", str(candidate), str(uploads), "1"
        ).returncode != 0

    with tempfile.TemporaryDirectory(prefix="sync-sender-upload-total-") as raw:
        base = Path(raw).resolve()
        candidate, uploads = roots(base)
        (uploads / "a.jpg").write_bytes(b"a" * 7)
        (uploads / "b.jpg").write_bytes(b"b" * 7)
        assert run_python_program(
            program, "preflight", str(candidate), str(uploads), "1"
        ).returncode != 0

    with tempfile.TemporaryDirectory(prefix="sync-sender-upload-directory-") as raw:
        base = Path(raw).resolve()
        candidate, uploads = roots(base)
        for index in range(4):
            (uploads / f"d{index}").mkdir()
        assert run_python_program(
            program, "preflight", str(candidate), str(uploads), "1"
        ).returncode != 0

    with tempfile.TemporaryDirectory(prefix="sync-sender-upload-db-limit-") as raw:
        base = Path(raw).resolve()
        candidate, uploads = roots(base)
        assert run_python_program(
            program, "preflight", str(candidate), str(uploads), "9"
        ).returncode != 0

    with tempfile.TemporaryDirectory(prefix="sg-", dir="/tmp") as raw:
        base = Path(raw).resolve()
        candidate, uploads = roots(base)
        external = base / "external"
        external.write_bytes(b"keep")
        (uploads / "linked.jpg").symlink_to(external)
        assert run_python_program(
            program, "preflight", str(candidate), str(uploads), "1"
        ).returncode != 0
        (uploads / "linked.jpg").unlink()
        hardlink = uploads / "hard.jpg"
        os.link(external, hardlink)
        assert run_python_program(
            program, "preflight", str(candidate), str(uploads), "1"
        ).returncode != 0
        hardlink.unlink()

        fifo = uploads / "blocking.fifo"
        os.mkfifo(fifo)
        try:
            rejected_fifo = subprocess.run(
                [
                    sys.executable,
                    "-I",
                    "-c",
                    program,
                    "preflight",
                    str(candidate),
                    str(uploads),
                    "1",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=2,
                check=False,
            )
        except subprocess.TimeoutExpired as error:
            raise AssertionError("FIFO inspection must fail without blocking") from error
        assert rejected_fifo.returncode != 0
        fifo.unlink()

        socket_path = uploads / "local.socket"
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            listener.bind(str(socket_path))
            rejected_socket = run_python_program(
                program, "preflight", str(candidate), str(uploads), "1"
            )
            assert rejected_socket.returncode != 0
        finally:
            listener.close()


def test_sender_staging_recovery(sender_text: str) -> None:
    source = localize_root_contract(
        heredoc_after(sender_text, "manage_sender_staging() {")
    )
    with tempfile.TemporaryDirectory(prefix="sync-sender-staging-recovery-") as raw:
        base = Path(raw).resolve()
        generation_root = base / "shuzijun-sync"
        staging_root = generation_root / "sender-staging"
        generation_root.mkdir(mode=0o700)
        staging_root.mkdir(mode=0o700)
        generation_root.chmod(0o700)
        staging_root.chmod(0o700)
        program = source.replace(
            'Path("/var/lib/shuzijun-sync")', f"Path({str(generation_root)!r})"
        ).replace(
            "os.chown(allocating, 0, 0)",
            "os.chown(allocating, os.getuid(), os.getgid())",
        )

        def run(
            action: str,
            target: Path | str = "",
            token: str = "",
            selected: str | None = None,
        ) -> subprocess.CompletedProcess[str]:
            return run_python_program(
                selected or program,
                action,
                str(generation_root),
                str(staging_root),
                str(target),
                token,
            )

        def add_file(root: Path, relative: str, payload: bytes) -> None:
            child = root / relative
            child.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            for parent in child.parents:
                if parent == root.parent:
                    break
                if parent == root or root in parent.parents:
                    parent.chmod(0o700)
            child.write_bytes(payload)
            child.chmod(0o600)

        # Model SIGKILL after allocation, after media copy and after DB export.
        for index, files in enumerate(
            (
                (),
                (("wp-content/uploads/hero.jpg", b"photo"),),
                (
                    ("wp-content/uploads/hero.jpg", b"photo"),
                    ("shuzijun-sync.sql.gz", b"database"),
                ),
            ),
            start=1,
        ):
            token = f"{index:032x}"
            batch = staging_root / f"batch.{token}"
            allocated = run("allocate", batch, token)
            assert allocated.returncode == 0, allocated.stderr
            for relative, payload in files:
                add_file(batch, relative, payload)
        cleaned = run("clean-stale")
        assert cleaned.returncode == 0, cleaned.stderr
        assert not list(staging_root.iterdir()), (
            "next run must remove create/copy/export SIGKILL leftovers"
        )

        # Kill exactly after the atomic retiring rename. A later cleaner must
        # accept the safe remaining subset even when the owner was already gone.
        token = "a" * 32
        batch = staging_root / f"batch.{token}"
        assert run("allocate", batch, token).returncode == 0
        add_file(batch, "wp-content/uploads/full.jpg", b"full-photo")
        killed_program = program.replace("import shutil\n", "import shutil\nimport signal\n").replace(
            "    shutil.rmtree(path)\n    os.fsync(staging_fd)",
            "    os.kill(os.getpid(), signal.SIGKILL)\n    os.fsync(staging_fd)",
            1,
        )
        killed = run("remove", batch, token, killed_program)
        assert killed.returncode == -signal.SIGKILL
        retiring = staging_root / f".retiring.{token}"
        assert not batch.exists() and retiring.is_dir()
        (retiring / ".sender-staging-owner.json").unlink()
        resumed = run("clean-stale")
        assert resumed.returncode == 0, resumed.stderr
        assert not retiring.exists(), "partial retiring deletion must be resumable"

        # Allocation can die before its ownership record is complete.
        token = "b" * 32
        allocating = staging_root / f".allocating.{token}"
        allocating.mkdir(mode=0o700)
        allocating.chmod(0o700)
        owner = allocating / ".sender-staging-owner.json"
        owner.write_bytes(b'{"token":"')
        owner.chmod(0o600)
        assert run("clean-stale").returncode == 0
        assert not allocating.exists()

        unknown = staging_root / "operator-note"
        unknown.write_bytes(b"preserve")
        rejected = run("clean-stale")
        assert rejected.returncode != 0 and unknown.read_bytes() == b"preserve"
        unknown.unlink()

        external = base / "external"
        external.write_bytes(b"unchanged")
        token = "c" * 32
        (staging_root / f"batch.{token}").symlink_to(external)
        rejected = run("clean-stale")
        assert rejected.returncode != 0 and external.read_bytes() == b"unchanged"
        (staging_root / f"batch.{token}").unlink()

        token = "d" * 32
        batch = staging_root / f"batch.{token}"
        assert run("allocate", batch, token).returncode == 0
        outside = base / "outside-hardlink"
        outside.write_bytes(b"unchanged")
        outside.chmod(0o600)
        os.link(outside, batch / "linked.jpg")
        rejected = run("clean-stale")
        assert rejected.returncode != 0 and outside.stat().st_nlink == 2
        (batch / "linked.jpg").unlink()
        assert run("clean-stale").returncode == 0


def test_primary_fpm_freeze_marker_linux(sender_text: str) -> None:
    if sys.platform != "linux":
        return
    if os.geteuid() != 0:
        raise AssertionError("primary freeze crash fixture must run as root")
    original = heredoc_after(sender_text, "primary_fpm_freeze_state() {")
    with tempfile.TemporaryDirectory(prefix="sync-primary-freeze-marker-") as raw:
        base = Path(raw).resolve()
        root = base / "shuzijun-sync"
        root.mkdir(mode=0o700)
        marker = root / "primary-fpm-freeze.json"
        systemctl = base / "systemctl"
        systemctl.write_text(
            "#!/bin/sh\n"
            "case \"$1\" in\n"
            "  show) printf '%s\\n' 'LoadState=loaded' 'ActiveState=active' "
            "'SubState=running' 'Result=success' 'MainPID=4242' 'Job=' ;;\n"
            "  start) exit 0 ;;\n"
            "  *) exit 1 ;;\n"
            "esac\n",
            encoding="ascii",
        )
        systemctl.chmod(0o755)
        program = original.replace(
            'Path("/run/shuzijun-sync")', f"Path({str(root)!r})"
        ).replace('"/usr/bin/systemctl"', repr(str(systemctl)))

        lock = root / "sync.lock"
        lock_descriptor = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
        lock_identity = (lock.stat().st_dev, lock.stat().st_ino)
        fcntl.flock(lock_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)

        def invoke(
            selected: str, mode: str, expected: str = "", owner: str = ""
        ) -> subprocess.CompletedProcess[str]:
            return run_python_program(
                selected,
                mode,
                str(root),
                str(marker),
                "php8.3-fpm.service",
                expected,
                owner,
                "120",
                "180",
            )

        def recover_and_recreate(selected: str) -> None:
            killed = invoke(selected, "create", owner=str(os.getpid()))
            assert killed.returncode == -signal.SIGKILL, killed.stderr
            if marker.exists():
                recovered = invoke(program, "recover")
                assert recovered.returncode == 0, recovered.stderr
                assert not marker.exists()
            recreated = invoke(program, "create", owner=str(os.getpid()))
            assert recreated.returncode == 0, recreated.stderr
            token = recreated.stdout.strip()
            assert len(token) == 64
            recovered = invoke(program, "recover", token)
            assert recovered.returncode == 0, recovered.stderr
            assert not list(root.glob(".primary-fpm-freeze.*"))
            assert (lock.stat().st_dev, lock.stat().st_ino) == lock_identity

        injections = (
            (
                "    descriptor = os.open(name, flags, 0o600, dir_fd=root_fd)\n",
                "    descriptor = os.open(name, flags, 0o600, dir_fd=root_fd)\n"
                "    os.kill(os.getpid(), signal.SIGKILL)\n",
            ),
            (
                "            written = os.write(descriptor, view)\n",
                "            written = os.write(descriptor, view)\n"
                "            os.kill(os.getpid(), signal.SIGKILL)\n",
            ),
            (
                "        os.fsync(descriptor)\n        metadata = os.fstat(descriptor)\n",
                "        os.fsync(descriptor)\n"
                "        os.kill(os.getpid(), signal.SIGKILL)\n"
                "        metadata = os.fstat(descriptor)\n",
            ),
            (
                "        rename_noreplace(root_fd, temporary, name)\n",
                "        rename_noreplace(root_fd, temporary, name)\n"
                "        os.kill(os.getpid(), signal.SIGKILL)\n",
            ),
        )
        for needle, replacement in injections:
            assert program.count(needle) == 1, needle
            selected = "import signal\n" + program.replace(needle, replacement, 1)
            recover_and_recreate(selected)

        unknown = root / ".primary-fpm-freeze.unknown"
        unknown.write_bytes(b"do-not-delete")
        unknown.chmod(0o600)
        rejected = invoke(program, "create", owner=str(os.getpid()))
        assert rejected.returncode != 0 and unknown.read_bytes() == b"do-not-delete"
        unknown.unlink()
        os.close(lock_descriptor)


def test_uploads_transaction_linux(receiver_text: str) -> None:
    """Exercise the exact transactional-media program on Linux renameat2."""
    if sys.platform != "linux":
        return
    if os.geteuid() != 0:
        raise AssertionError("Linux transactional-media fixture must run as root")
    program = heredoc_after(receiver_text, "manage_uploads_transaction() {")
    with tempfile.TemporaryDirectory(prefix="sync-uploads-transaction-test-") as raw:
        base = Path(raw).resolve()
        fake_var = base / "var"
        fake_lib = fake_var / "lib"
        sync_root = fake_lib / "shuzijun-sync"
        state_root = sync_root / "state"
        release_root = sync_root / "uploads-releases"
        live = fake_var / "www/html/shuzijun.com.cn/wp-content/uploads"
        backup_root = fake_var / "backups"
        for directory, mode in (
            (fake_var, 0o755),
            (fake_lib, 0o755),
            (sync_root, 0o700),
            (state_root, 0o700),
            (backup_root, 0o755),
        ):
            directory.mkdir(mode=mode, parents=True, exist_ok=True)
            directory.chmod(mode)
        program = program.replace(
            'Path("/var")', f"Path({str(fake_var)!r})"
        ).replace(
            'Path("/var/lib")', f"Path({str(fake_lib)!r})"
        ).replace(
            'Path("/var/backups")', f"Path({str(backup_root)!r})"
        ).replace(
            'Path("/var/www/html/shuzijun.com.cn/wp-content/uploads")',
            f"Path({str(live)!r})",
        )

        required = (
            "2025/04/gongan-beian.png",
            "hero-images/hero-1.jpg",
            "showreel/hls-20260826a/high/index.m3u8",
            "showreel/hls-20260826a/high/segment-000.ts",
        )

        def write_tree(root: Path, label: str, directory_mode: int, file_mode: int) -> None:
            root.mkdir(mode=directory_mode, parents=True)
            root.chmod(directory_mode)
            for relative in required:
                child = root / relative
                child.parent.mkdir(mode=directory_mode, parents=True, exist_ok=True)
                for parent in (child.parent, *child.parents):
                    if parent == root.parent:
                        break
                    if parent == root or root in parent.parents:
                        parent.chmod(directory_mode)
                child.write_bytes(f"{label}:{relative}\n".encode("utf-8"))
                child.chmod(file_mode)

        def write_generation(path: Path, generation: int) -> None:
            path.write_text(f"{generation}\n", encoding="ascii")
            path.chmod(0o600)

        def make_claim(generation: int, label: str) -> Path:
            incoming = sync_root / "incoming"
            incoming.mkdir(mode=0o700, exist_ok=True)
            incoming.chmod(0o700)
            claim = incoming / f"batch.gen{generation}"
            claim.mkdir(mode=0o700)
            uploads = claim / "wp-content/uploads"
            write_tree(uploads, label, 0o700, 0o600)
            (claim / "wp-content").chmod(0o700)
            files = []
            for child in sorted(uploads.rglob("*")):
                if child.is_file():
                    relative = child.relative_to(claim).as_posix()
                    payload = child.read_bytes()
                    files.append(
                        {
                            "path": relative,
                            "sha256": hashlib.sha256(payload).hexdigest(),
                            "size": len(payload),
                        }
                    )
            document = {"files": files, "generation": generation, "version": 2}
            manifest = claim / "shuzijun-sync-manifest.json"
            manifest.write_text(
                json.dumps(document, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
                + "\n",
                encoding="ascii",
            )
            manifest.chmod(0o600)
            return claim

        active = state_root / "active-uploads-generation"
        accepted = state_root / "highest-accepted-generation"
        transaction = state_root / "uploads-transaction.json"
        armed = state_root / "fpm-activation-guard-v4.armed"
        committed = state_root / "fpm-activation-guard-v4.committed"
        write_tree(live, "generation-6", 0o755, 0o644)
        web = pwd.getpwnam("www-data")
        for child in sorted(live.rglob("*"), reverse=True):
            os.chown(child, web.pw_uid, web.pw_gid, follow_symlinks=False)
        os.chown(live, web.pw_uid, web.pw_gid)
        write_generation(accepted, 6)

        def run(action: str, generation: int = 0, claim: Path | None = None,
                backup: Path | None = None,
                selected: str | None = None) -> subprocess.CompletedProcess[str]:
            return run_python_program(
                selected or program,
                action,
                str(sync_root),
                str(release_root),
                str(state_root),
                str(active),
                str(transaction),
                str(live),
                str(accepted),
                str(generation),
                str(claim or Path("/")),
                str(backup or Path("/")),
            )

        def bootstrap_kill_program(needle: str) -> str:
            assert program.count(needle) == 1
            return program.replace(
                "import shutil\n", "import shutil\nimport signal\n", 1
            ).replace(
                needle,
                needle + "        os.kill(os.getpid(), signal.SIGKILL)\n",
                1,
            )

        # Every durable prefix of first-time bootstrap is recoverable, while
        # an unexplained active-without-root state remains fail closed.
        killed_after_mkdir = run(
            "bootstrap",
            6,
            selected=bootstrap_kill_program("        os.mkdir(release_root, 0o700)\n"),
        )
        assert killed_after_mkdir.returncode == -signal.SIGKILL
        assert release_root.is_dir() and not active.exists()
        assert run("bootstrap", 6).returncode == 0
        active.unlink()
        release_root.rmdir()

        killed_before_active = run(
            "bootstrap",
            6,
            selected=bootstrap_kill_program("        fsync_directory(sync_root)\n"),
        )
        assert killed_before_active.returncode == -signal.SIGKILL
        assert release_root.is_dir() and not active.exists()
        assert run("bootstrap", 6).returncode == 0
        active.unlink()
        release_root.rmdir()

        active_publication = (
            "        atomic_write(active_path, f\"{generation}\\n\".encode(\"ascii\"), "
            '".active-generation.", True)\n'
        )
        killed_after_active = run(
            "bootstrap",
            6,
            selected=bootstrap_kill_program(active_publication),
        )
        assert killed_after_active.returncode == -signal.SIGKILL
        assert release_root.is_dir() and active.read_text(encoding="ascii") == "6\n"
        boot = run("bootstrap", 6)
        assert boot.returncode == 0, boot.stderr
        assert run("bootstrap", 6).returncode == 0, "bootstrap must be idempotent"
        assert active.read_text(encoding="ascii") == "6\n"
        release_id6 = run("bootstrap-release-id", 6).stdout.strip()
        assert len(release_id6) == 64
        nonce6 = "6" * 64
        committed.write_text(f"6 {release_id6} {nonce6}\n", encoding="ascii")
        committed.chmod(0o600)
        assert run("publish-stable", 6).returncode == 0
        stable = run("validate-activation", 6)
        assert stable.returncode == 0 and stable.stdout == "6\n"

        claim7 = make_claim(7, "generation-7")
        backup7 = backup_root / "shuzijun-sync-v1-20260903-010101"
        killed_mid_chown = program.replace(
            "import shutil\n",
            "import shutil\nimport signal\n",
            1,
        ).replace(
            "            os.chown(name, www.pw_uid, www.pw_gid, "
            "dir_fd=descriptor, follow_symlinks=False)\n",
            "            os.chown(name, www.pw_uid, www.pw_gid, "
            "dir_fd=descriptor, follow_symlinks=False)\n"
            "            os.kill(os.getpid(), signal.SIGKILL)\n",
            1,
        )
        interrupted_prepare = run(
            "prepare", 7, claim7, backup7, selected=killed_mid_chown
        )
        assert interrupted_prepare.returncode == -signal.SIGKILL
        assert transaction.exists()
        partial_document = json.loads(transaction.read_text(encoding="ascii"))
        assert partial_document["phase"] == "staging"
        partial_candidate = release_root / partial_document["candidate_name"]
        assert partial_candidate.is_dir()
        recovered_prepare = run("rollback-media", 7)
        assert recovered_prepare.returncode == 0, recovered_prepare.stderr
        assert recovered_prepare.stdout == "clean\n" and not transaction.exists()
        restored_source = claim7 / "wp-content/uploads"
        assert restored_source.is_dir()
        for child in (restored_source, *restored_source.rglob("*")):
            assert child.stat().st_uid == 0 and child.stat().st_gid == 0
            assert stat_mode(child) == (0o700 if child.is_dir() else 0o600)

        prepared = run("prepare", 7, claim7, backup7)
        assert prepared.returncode == 0, (
            prepared.stderr
            + repr(
                [
                    (
                        child.relative_to(claim7).as_posix(),
                        child.stat().st_uid,
                        child.stat().st_gid,
                        stat_mode(child),
                        child.stat().st_nlink,
                        child.stat().st_size,
                        child.stat().st_blocks,
                    )
                    for child in claim7.rglob("*")
                ]
            )
        )
        prepared_identity = run("validate-prepared", 7)
        assert prepared_identity.returncode == 0
        assert prepared_identity.stdout == "7\n"
        assert run("set-phase", 7, Path("accepted")).returncode != 0
        write_generation(accepted, 7)
        assert run("set-phase", 7, Path("accepted")).returncode == 0
        assert run("set-phase", 7, Path("database-importing")).returncode == 0
        assert run("set-phase", 7, Path("database-imported")).returncode == 0
        assert run("exchange", 7).returncode == 0
        assert run("publish-active", 7).returncode == 0
        assert run("validate-commit", 7).returncode != 0, (
            "activated is a crash boundary, not an activation-safe commit"
        )
        assert run("set-phase", 7, Path("commit-ready")).returncode == 0
        assert run("validate-activation", 7).returncode != 0
        release_id7 = run("activation-release-id", 7).stdout.strip()
        assert len(release_id7) == 64 and release_id7 != release_id6
        nonce7 = "7" * 64
        armed.write_text(f"7 {release_id7} {nonce7}\n", encoding="ascii")
        armed.chmod(0o600)
        committed.write_text(
            f"7 {release_id7} {'b' * 64}\n", encoding="ascii"
        )
        assert run("validate-activation", 7).returncode != 0, (
            "an old/same-generation commit nonce must not replay a new activation"
        )
        committed.write_text(f"7 {release_id7} {nonce7}\n", encoding="ascii")
        assert run("validate-activation", 7).returncode == 0
        validated = run("validate-commit", 7)
        assert validated.returncode == 0 and validated.stdout == "7\n"
        assert run("set-phase", 7, Path("committed")).returncode == 0
        assert run("validate-commit", 7).returncode == 0
        committed_rollback = run("rollback-media", 7)
        assert committed_rollback.returncode == 0
        assert committed_rollback.stdout == "committed\n", (
            "a crash after the durable commit must never roll media back"
        )
        killed_after_release = program.replace(
            "import shutil\n",
            "import shutil\nimport signal\n",
            1,
        ).replace(
            "    write_active_release(active_release_document(document), True)\n",
            "    write_active_release(active_release_document(document), True)\n"
            "    os.kill(os.getpid(), signal.SIGKILL)\n",
            1,
        )
        interrupted_finalize = run("finalize", 7, selected=killed_after_release)
        assert interrupted_finalize.returncode == -signal.SIGKILL
        assert transaction.exists() and (state_root / "active-release-v4.json").exists()

        killed_after_retained_rename = program.replace(
            "import shutil\n",
            "import shutil\nimport signal\n",
            1,
        ).replace(
            "        os.rename(candidate, retained)\n",
            "        os.rename(candidate, retained)\n"
            "        os.kill(os.getpid(), signal.SIGKILL)\n",
            1,
        )
        interrupted_finalize = run(
            "finalize", 7, selected=killed_after_retained_rename
        )
        assert interrupted_finalize.returncode == -signal.SIGKILL
        assert transaction.exists()
        assert run("finalize", 7).returncode == 0
        assert not transaction.exists()
        active_release = state_root / "active-release-v4.json"
        release_document = json.loads(active_release.read_text(encoding="ascii"))
        assert set(release_document) == {
            "evidence_sha256",
            "generation",
            "release_id",
            "uploads_dev",
            "uploads_ino",
            "version",
        }
        assert release_document["generation"] == 7
        assert release_document["release_id"] == release_id7
        assert release_document["version"] == 4
        assert stat_mode(active_release) == 0o600 and active_release.stat().st_nlink == 1
        assert active.read_text(encoding="ascii") == "7\n"
        assert b"generation-7" in (live / required[0]).read_bytes()
        assert run("validate-commit", 7).returncode == 0
        assert run("validate-activation", 7).returncode == 0

        # A stable same-generation restart keeps the immutable release id but
        # gets a fresh activation nonce. The old commit cannot replay the newly
        # armed attempt; publishing the exact new triple authorizes it without
        # rewriting the active-release record.
        stable_record_before = active_release.read_bytes()
        restart_nonce = "8" * 64
        armed.write_text(
            f"7 {release_id7} {restart_nonce}\n", encoding="ascii"
        )
        assert run("validate-activation", 7).returncode != 0
        committed.write_text(
            f"7 {release_id7} {restart_nonce}\n", encoding="ascii"
        )
        assert run("validate-activation", 7).returncode == 0
        assert active_release.read_bytes() == stable_record_before

        no_deep_hash = program.replace(
            "def hash_file(path):\n"
            "    digest = hashlib.sha256()\n"
            "    with path.open(\"rb\", buffering=0) as stream:\n"
            "        for chunk in iter(lambda: stream.read(1024 * 1024), b\"\"):\n"
            "            digest.update(chunk)\n"
            "    return digest.hexdigest()\n",
            "def hash_file(path):\n"
            "    raise RuntimeError('deep hash entered activation path')\n",
            1,
        )
        assert run("active-generation", selected=no_deep_hash).stdout == "7\n"
        assert run("validate-activation", 7, selected=no_deep_hash).returncode == 0

        # A later accepted apply can restore generation 7 after its active
        # publication but must keep accepted monotonic and fail activation.
        claim8 = make_claim(8, "generation-8")
        backup8 = backup_root / "shuzijun-sync-v1-20260903-020202"
        assert run("prepare", 8, claim8, backup8).returncode == 0
        write_generation(accepted, 8)
        for phase in ("accepted", "database-importing", "database-imported"):
            assert run("set-phase", 8, Path(phase)).returncode == 0
        assert run("exchange", 8).returncode == 0
        assert run("publish-active", 8).returncode == 0
        rolled = run("rollback-media", 8)
        assert rolled.returncode == 0 and rolled.stdout == "database\n"
        assert active.read_text(encoding="ascii") == "7\n"
        assert accepted.read_text(encoding="ascii") == "8\n"
        assert b"generation-7" in (live / required[0]).read_bytes()
        assert run("validate-commit", 8).returncode != 0
        candidate8 = release_root / json.loads(
            transaction.read_text(encoding="ascii")
        )["candidate_name"]
        for child in candidate8.iterdir():
            if child.is_dir():
                shutil.rmtree(child)
            else:
                child.unlink()
        killed_before_delete = program.replace(
            "import shutil\n",
            "import shutil\nimport signal\n",
            1,
        ).replace(
            "        secure_remove_tree(\n"
            "            candidate,\n",
            "        os.kill(os.getpid(), signal.SIGKILL)\n"
            "        secure_remove_tree(\n"
            "            candidate,\n",
            1,
        )
        interrupted = run("finish-rollback", 8, selected=killed_before_delete)
        assert interrupted.returncode == -signal.SIGKILL
        assert candidate8.is_dir() and not list(candidate8.iterdir())
        assert transaction.exists()
        assert run("finish-rollback", 8).returncode == 0
        assert not transaction.exists()

        # The exact crash window after transaction=commit-ready but before the
        # durable guard commit remains rollback-safe.  Once a valid commit is
        # present the shell recovery path, not this primitive, treats it as a
        # forward-only committed recovery.
        claim9 = make_claim(9, "generation-9")
        backup9 = backup_root / "shuzijun-sync-v1-20260903-030303"
        assert run("prepare", 9, claim9, backup9).returncode == 0
        write_generation(accepted, 9)
        for phase in ("accepted", "database-importing", "database-imported"):
            assert run("set-phase", 9, Path(phase)).returncode == 0
        assert run("exchange", 9).returncode == 0
        assert run("publish-active", 9).returncode == 0
        assert run("set-phase", 9, Path("commit-ready")).returncode == 0
        assert run("validate-commit", 9).returncode == 0
        rolled_commit_ready = run("rollback-media", 9)
        assert rolled_commit_ready.returncode == 0
        assert rolled_commit_ready.stdout == "database\n"
        assert active.read_text(encoding="ascii") == "7\n"
        assert accepted.read_text(encoding="ascii") == "9\n"
        assert b"generation-7" in (live / required[0]).read_bytes()
        assert run("validate-commit", 9).returncode != 0
        candidate9 = release_root / json.loads(
            transaction.read_text(encoding="ascii")
        )["candidate_name"]
        killed_after_delete = program.replace(
            "import shutil\n",
            "import shutil\nimport signal\n",
            1,
        ).replace(
            "    shutil.rmtree(path)\n    fsync_directory(path.parent)",
            "    shutil.rmtree(path)\n"
            "    os.kill(os.getpid(), signal.SIGKILL)\n"
            "    fsync_directory(path.parent)",
            1,
        )
        interrupted = run("finish-rollback", 9, selected=killed_after_delete)
        assert interrupted.returncode == -signal.SIGKILL
        assert not candidate9.exists() and transaction.exists()
        assert run("finish-rollback", 9).returncode == 0
        assert not transaction.exists()


def test_receiver_failure_guard(receiver_text: str) -> None:
    start = receiver_text.index("finish_receiver() {")
    end = receiver_text.index("\n}\n", start) + 3
    function = receiver_text[start:end].replace("rm -rf --one-file-system --", "rm -rf --")
    with tempfile.TemporaryDirectory(prefix="sync-receiver-guard-test-") as raw:
        root = Path(raw).resolve()
        claim = root / "batch.test"
        claim.mkdir()
        marker = root / "isolated"
        harness = (
            "set -euo pipefail\n"
            + function
            + "\nisolate_failed_fpm() { printf isolated > \"$MARKER\"; }\n"
            + "remove_claim_tree() { rm -rf -- \"$1\"; }\n"
            + "CLAIM_ROOT=$1\nCLAIM=$2\nMARKER=$3\n"
            + "STATE_ROOT=$1\nROLLBACK_SQL=\n"
            + "UPLOADS_TRANSACTION=$1/nonexistent-transaction\n"
            + "MUTATION_GUARD=1\nAPPLY_SUCCEEDED=0\n"
            + "finish_receiver 23\n"
        )
        failed = subprocess.run(
            ["/bin/bash", "-c", harness, "guard-test", str(root), str(claim), str(marker)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        assert failed.returncode == 23
        assert marker.read_text(encoding="utf-8") == "isolated"
        assert not claim.exists()

        # A metadata syncfs/revalidation failure occurs after the prepared
        # transaction is durable but before MUTATION_GUARD.  EXIT must roll
        # that preactivation transaction back while the healthy FPM remains
        # online, and only then may it remove the claim.
        prepared_claim = root / "batch.prepared-sync-failure"
        prepared_claim.mkdir()
        prepared_transaction = root / "prepared-transaction"
        prepared_transaction.write_text("prepared\n", encoding="ascii")
        prepared_rollback = root / "prepared-rollback"
        prepared_isolation = root / "prepared-isolation"
        prepared_harness = (
            "set -euo pipefail\n"
            + function
            + "\nrollback_incomplete_transaction() { "
            + ": > \"$ROLLED\"; rm -f -- \"$UPLOADS_TRANSACTION\"; return 0; }\n"
            + "isolate_failed_fpm() { : > \"$ISOLATED\"; return 0; }\n"
            + "remove_claim_tree() { rm -rf -- \"$1\"; }\n"
            + "transaction_is_durably_committed() { return 1; }\n"
            + "CLAIM_ROOT=$1\nCLAIM=$2\nUPLOADS_TRANSACTION=$3\n"
            + "ROLLED=$4\nISOLATED=$5\nSTATE_ROOT=$1\nROLLBACK_SQL=\n"
            + "PREPARE_IN_PROGRESS=1\nMUTATION_GUARD=0\n"
            + "APPLY_SUCCEEDED=0\nPOST_COMMIT=0\nfinish_receiver 51\n"
        )
        prepared_failure = subprocess.run(
            [
                "/bin/bash",
                "-c",
                prepared_harness,
                "prepared-syncfs-failure",
                str(root),
                str(prepared_claim),
                str(prepared_transaction),
                str(prepared_rollback),
                str(prepared_isolation),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        assert prepared_failure.returncode == 51, prepared_failure.stderr
        assert prepared_rollback.exists() and not prepared_transaction.exists()
        assert not prepared_isolation.exists(), "preactivation failure must not stop FPM"
        assert not prepared_claim.exists()

        marker.unlink()
        accidental = root / "batch.accidental-success"
        accidental.mkdir()
        accidental_harness = harness.replace("finish_receiver 23", "finish_receiver 0")
        accidental_result = subprocess.run(
            [
                "/bin/bash",
                "-c",
                accidental_harness,
                "guard-test",
                str(root),
                str(accidental),
                str(marker),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        assert accidental_result.returncode == 1
        assert marker.exists() and not accidental.exists()

        marker.unlink()
        successful = root / "batch.success"
        successful.mkdir()
        success_harness = harness.replace("APPLY_SUCCEEDED=0", "APPLY_SUCCEEDED=1").replace(
            "finish_receiver 23", "finish_receiver 0"
        )
        result = subprocess.run(
            [
                "/bin/bash",
                "-c",
                success_harness,
                "guard-test",
                str(root),
                str(successful),
                str(marker),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        assert result.returncode == 0 and not marker.exists() and not successful.exists()

        signaled = root / "batch.signal"
        signaled.mkdir()
        signal_harness = harness.replace(
            "finish_receiver 23", "trap 'finish_receiver $?' EXIT\ntrap 'exit 130' TERM\nkill -TERM $$"
        )
        result = subprocess.run(
            [
                "/bin/bash",
                "-c",
                signal_harness,
                "guard-test",
                str(root),
                str(signaled),
                str(marker),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        assert result.returncode == 130 and marker.exists() and not signaled.exists()


def test_preactivation_metadata_durability(receiver_text: str) -> None:
    start = receiver_text.index(
        "PREPARE_IN_PROGRESS=1\n"
        'prepare_uploads_transaction "$GENERATION" "$CLAIM" "$BACKUP_DEST"\n'
    )
    end = receiver_text.index("if ! isolate_failed_fpm; then", start)
    segment = receiver_text[start:end]
    assert 'sync -f "$SYNC_ROOT"' in segment
    assert segment.index('sync -f "$SYNC_ROOT"') < segment.index(
        'PREPARED_AFTER_SYNC=$(validate_prepared_uploads_transaction'
    ) < segment.index("MUTATION_GUARD=1")

    def run(sync_result: int) -> tuple[subprocess.CompletedProcess[str], list[str], str]:
        with tempfile.TemporaryDirectory(prefix="sync-metadata-durability-") as raw:
            root = Path(raw).resolve()
            trace = root / "trace"
            state = root / "state"
            harness = (
                "set -euo pipefail\n"
                + "TRACE=$1\nSTATE=$2\nSYNC_ROOT=$3\nSYNC_RESULT=$4\n"
                + "GENERATION=7\nCLAIM=/claim\nBACKUP_DEST=/var/backups/fixture\n"
                + "PREPARE_IN_PROGRESS=0\nMUTATION_GUARD=0\n"
                + "trap 'printf \"%s %s\\n\" \"$PREPARE_IN_PROGRESS\" "
                + "\"$MUTATION_GUARD\" > \"$STATE\"' EXIT\n"
                + "prepare_uploads_transaction() { printf 'prepare\\n' >> \"$TRACE\"; }\n"
                + "sync() { [[ \"$1\" == -f && \"$2\" == \"$SYNC_ROOT\" ]]; "
                + "printf 'sync\\n' >> \"$TRACE\"; return \"$SYNC_RESULT\"; }\n"
                + "validate_prepared_uploads_transaction() { "
                + "printf 'validate\\n' >> \"$TRACE\"; printf '7\\n'; }\n"
                + segment
            )
            result = subprocess.run(
                [
                    "/bin/bash",
                    "-c",
                    harness,
                    "metadata-durability",
                    str(trace),
                    str(state),
                    str(root),
                    str(sync_result),
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            return (
                result,
                trace.read_text(encoding="ascii").splitlines(),
                state.read_text(encoding="ascii").strip(),
            )

    completed, trace, state = run(0)
    assert completed.returncode == 0, completed.stderr
    assert trace == ["prepare", "sync", "validate"]
    assert state == "0 1"

    failed, trace, state = run(19)
    assert failed.returncode == 19, failed.stderr
    assert trace == ["prepare", "sync"]
    assert state == "1 0", "syncfs failure must remain preactivation"


def test_post_commit_supervision(receiver_text: str) -> None:
    finish = shell_function(receiver_text, "finish_receiver")

    def interrupted(mode: str, fallback: bool = False) -> tuple[int, bool, bool, str]:
        with tempfile.TemporaryDirectory(prefix="sync-post-commit-supervisor-") as raw:
            root = Path(raw).resolve()
            isolated = root / "isolated"
            rolled = root / "rolled"
            transaction = root / "uploads-transaction.json"
            if fallback:
                transaction.write_text("committed\n", encoding="ascii")
            body = {
                "error": "false\n",
                "term": "kill -TERM $$\n",
                "hang": "( sleep 0.1; kill -TERM $$ ) & wait $!\n",
            }[mode]
            harness = (
                "set -euo pipefail\n"
                + finish
                + "\nisolate_failed_fpm() { : > \"$ISOLATED\"; }\n"
                + "rollback_incomplete_transaction() { : > \"$ROLLED\"; return 0; }\n"
                + "transaction_is_durably_committed() { return 0; }\n"
                + "remove_claim_tree() { return 0; }\n"
                + "remove_rollback_sql() { return 0; }\n"
                + "CLAIM=\nROLLBACK_SQL=\nCLAIM_ROOT=$1\nSTATE_ROOT=$1\n"
                + "UPLOADS_TRANSACTION=$2\nMUTATION_GUARD=1\nAPPLY_SUCCEEDED=0\n"
                + ("POST_COMMIT=0\n" if fallback else "POST_COMMIT=1\n")
                + "ISOLATED=$3\nROLLED=$4\n"
                + "trap 'finish_receiver $?' EXIT\ntrap 'exit 130' TERM HUP INT\n"
                + body
            )
            result = subprocess.run(
                [
                    "/bin/bash",
                    "-c",
                    harness,
                    "post-commit-supervisor",
                    str(root),
                    str(transaction),
                    str(isolated),
                    str(rolled),
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=3,
                check=False,
            )
            return result.returncode, isolated.exists(), rolled.exists(), result.stderr

    failed = interrupted("error")
    assert failed[0] == 1 and not failed[1] and not failed[2], failed[3]
    terminated = interrupted("term")
    assert terminated[0] == 130 and not terminated[1] and not terminated[2], terminated[3]
    hung = interrupted("hang")
    assert hung[0] == 130 and not hung[1] and not hung[2], hung[3]
    fallback = interrupted("error", fallback=True)
    assert fallback[0] == 1 and not fallback[1] and not fallback[2], fallback[3]

    recover = shell_function(receiver_text, "recover_uploads_transaction_if_needed")
    with tempfile.TemporaryDirectory(prefix="sync-post-commit-recovery-") as raw:
        root = Path(raw).resolve()
        transaction = root / "uploads-transaction.json"
        transaction.write_text("committed\n", encoding="ascii")
        finalized = root / "finalized"
        isolated = root / "isolated"
        harness = (
            "set -euo pipefail\n"
            + recover
            + "\nmanage_uploads_transaction() {\n"
            + "  case \"$1\" in\n"
            + "    inspect) printf '7 6 committed /backup\\n' ;;\n"
            + "    validate-commit) printf '7\\n' ;;\n"
            + "    finalize) : > \"$FINALIZED\" ;;\n"
            + "    *) return 1 ;;\n"
            + "  esac\n}\n"
            + "validate_fpm_guard_commit_matches_accepted() { return 0; }\n"
            + "verify_webroot_security() { return 0; }\n"
            + "validate_database_markers() { return 0; }\n"
            + "verify_fpm_ready() { return 0; }\n"
            + "probe_standby_runtime() { return 0; }\n"
            + "isolate_failed_fpm() { : > \"$ISOLATED\"; return 0; }\n"
            + "set_uploads_transaction_phase() { return 0; }\n"
            + "finalize_uploads_transaction() { manage_uploads_transaction finalize; }\n"
            + "rollback_incomplete_transaction() { return 1; }\n"
            + "UPLOADS_TRANSACTION=$1\nFINALIZED=$2\nISOLATED=$3\nPOST_COMMIT=0\n"
            + "recover_uploads_transaction_if_needed\n"
        )
        resumed = subprocess.run(
            [
                "/bin/bash",
                "-c",
                harness,
                "post-commit-recovery",
                str(transaction),
                str(finalized),
                str(isolated),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        assert resumed.returncode == 0, resumed.stderr
        assert finalized.exists() and not isolated.exists()


def test_durable_fpm_unmask(receiver_text: str) -> None:
    function = shell_function(receiver_text, "durably_unmask_fpm")
    unmask = function.index('systemctl unmask "$FPM_SERVICE"')
    persist = function.index("sync -f /etc/systemd/system", unmask)
    reload_check = function.index("--property=LoadState --value", persist)
    enabled_check = function.index('read_unit_file_state "$FPM_SERVICE"', reload_check)
    job_check = function.index("--property=Job --value", enabled_check)
    assert unmask < persist < reload_check < enabled_check < job_check

    with tempfile.TemporaryDirectory(prefix="sync-durable-unmask-") as raw:
        root = Path(raw).resolve()
        log = root / "calls"
        harness = "set -euo pipefail\n" + function + r'''
systemctl() {
  case "$*" in
    *'unmask '*) printf 'unmask\n' >> "$LOG" ;;
    *LoadState*) printf '%s\n' "$LOAD_STATE"; return "$LOAD_STATUS" ;;
    *Job*) printf '%s\n' "$JOB"; return "$JOB_STATUS" ;;
    *'start '*) printf 'start\n' >> "$LOG" ;;
    *) return 1 ;;
  esac
}
sync() { printf 'sync\n' >> "$LOG"; return "$SYNC_STATUS"; }
read_unit_file_state() { printf '%s\n' "$ENABLED_STATE"; return "$ENABLED_STATUS"; }
FPM_SERVICE=fpm.service
LOG=$1
SYNC_STATUS=$2
LOAD_STATE=$3
LOAD_STATUS=$4
ENABLED_STATE=$5
ENABLED_STATUS=$6
JOB=$7
JOB_STATUS=$8
if durably_unmask_fpm; then
  systemctl start "$FPM_SERVICE"
  exit 0
fi
exit 42
'''

        def run(*values: str) -> tuple[subprocess.CompletedProcess[str], list[str]]:
            try:
                log.unlink()
            except FileNotFoundError:
                pass
            result = subprocess.run(
                ["/bin/bash", "-c", harness, "durable-unmask-test", str(log), *values],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            calls = log.read_text(encoding="ascii").splitlines() if log.exists() else []
            return result, calls

        failed_sync, calls = run("1", "loaded", "0", "enabled", "0", "", "0")
        assert failed_sync.returncode == 42 and calls == ["unmask", "sync"]
        replayed_mask, calls = run("0", "masked", "0", "enabled", "0", "", "0")
        assert replayed_mask.returncode == 42 and calls == ["unmask", "sync"]
        output_then_timeout, calls = run(
            "0", "loaded", "124", "enabled", "0", "", "0"
        )
        assert output_then_timeout.returncode == 42 and calls == ["unmask", "sync"]
        successful, calls = run("0", "loaded", "0", "enabled", "0", "", "0")
        assert successful.returncode == 0 and calls == ["unmask", "sync", "start"]


def test_pending_stable_activation_resume(receiver_text: str) -> None:
    durable_unmask = shell_function(receiver_text, "durably_unmask_fpm")
    baseline = shell_function(receiver_text, "ensure_receiver_baseline")
    nonce = "a" * 64
    for failure in ("arm", "start", "verify", "probe", "commit"):
        with tempfile.TemporaryDirectory(prefix="sync-stable-resume-") as raw:
            root = Path(raw).resolve()
            log = root / "arm.log"
            started = root / "started"
            failed_once = root / "failed-once"
            harness = "set -euo pipefail\n" + durable_unmask + baseline + r'''
manage_uploads_transaction() {
  [[ "$1" == active-generation ]] && printf '7\n'
}
read_accepted_generation() { printf '7\n'; }
validate_fpm_guard_commit_matches_accepted() { return 1; }
read_pending_stable_activation() { printf '7 %s\n' "$PENDING"; }
isolate_failed_fpm() { rm -f "$STARTED"; return 0; }
verify_fpm_ready() {
  [[ -e "$STARTED" ]] || return 1
  if [[ "$FAIL" == verify && ! -e "$FAILED_ONCE" ]]; then
    : > "$FAILED_ONCE"
    return 1
  fi
}
probe_standby_runtime() {
  if [[ "$FAIL" == probe && ! -e "$FAILED_ONCE" ]]; then
    : > "$FAILED_ONCE"
    return 1
  fi
}
arm_fpm_activation_guard() {
  printf '%s %s\n' "$1" "${2-}" >> "$LOG"
  [[ "$1" == 7 && "${2-}" == resume ]] || return 1
  if [[ "$FAIL" == arm && ! -e "$FAILED_ONCE" ]]; then
    : > "$FAILED_ONCE"
    return 1
  fi
}
commit_fpm_activation_guard() {
  if [[ "$FAIL" == commit && ! -e "$FAILED_ONCE" ]]; then
    : > "$FAILED_ONCE"
    return 1
  fi
}
systemctl() {
  case "$*" in
    *LoadState*) printf 'loaded\n' ;;
    *Job*) printf '\n' ;;
    *ActiveState*) printf 'inactive\n' ;;
    *SubState*) printf 'dead\n' ;;
    *Result*) printf 'success\n' ;;
    *ExecMainStatus*) printf '0\n' ;;
    *'unmask '*) return 0 ;;
    *'start '*)
      if [[ "$FAIL" == start && ! -e "$FAILED_ONCE" ]]; then
        : > "$FAILED_ONCE"
        return 1
      fi
      : > "$STARTED"
      ;;
    *) return 1 ;;
  esac
}
sync() { return 0; }
read_unit_file_state() { printf 'enabled\n'; }
FPM_GUARD_UNIT=guard.service
FPM_SERVICE=fpm.service
LOG=$1
STARTED=$2
FAILED_ONCE=$3
FAIL=$4
PENDING=$5
if ensure_receiver_baseline; then exit 71; fi
rm -f "$STARTED"
FAIL=none
ensure_receiver_baseline
'''
            result = subprocess.run(
                [
                    "/bin/bash", "-c", harness, "stable-resume-test",
                    str(log), str(started), str(failed_once), failure, nonce,
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            assert result.returncode == 0, (failure, result.stdout, result.stderr)
            assert log.read_text(encoding="ascii").splitlines() == [
                "7 resume", "7 resume"
            ]

    recover = shell_function(receiver_text, "recover_uploads_transaction_if_needed")
    assert recover.index('set_uploads_transaction_phase "$generation" committed') < (
        recover.index('arm_fpm_activation_guard "$generation"')
    )
    assert recover.index('finalize_uploads_transaction "$generation"') < (
        recover.index('arm_fpm_activation_guard "$generation"')
    )


def test_fpm_guard_state(receiver_text: str) -> None:
    prepare = localize_root_contract(
        heredoc_after(receiver_text, "prepare_fpm_guard_state() {")
    )
    reset_program = localize_root_contract(
        heredoc_after(receiver_text, "reset_fpm_guard_attempt_state() {")
    )
    publish = localize_root_contract(
        heredoc_after(receiver_text, "publish_fpm_guard_marker() {")
    )
    validate = localize_root_contract(
        heredoc_after(receiver_text, "read_fpm_guard_marker() {")
    )

    with tempfile.TemporaryDirectory(prefix="sync-fpm-guard-state-test-") as raw:
        root = Path(raw).resolve() / "state"
        root.mkdir(mode=0o700)
        lease = root / "fpm-activation-guard.lease"
        armed = root / "fpm-activation-guard-v4.armed"
        committed = root / "fpm-activation-guard-v4.committed"
        release6 = "a" * 64
        release7 = "b" * 64
        nonce6 = "6" * 64
        nonce7 = "7" * 64
        prepared = run_python_program(
            prepare, str(root), str(lease), str(armed), str(committed), "7"
        )
        assert prepared.returncode == 0, prepared.stderr
        assert lease.read_bytes() == b"" and stat_mode(lease) == 0o600

        published = run_python_program(
            publish, str(root), str(armed), "7", release7, nonce7
        )
        assert published.returncode == 0, published.stderr
        read_armed = run_python_program(validate, str(root), str(armed), "7")
        assert read_armed.returncode == 0
        assert read_armed.stdout == f"{release7} {nonce7}\n"
        assert run_python_program(
            publish, str(root), str(armed), "7", release7, nonce7
        ).returncode == 0
        assert run_python_program(
            publish, str(root), str(armed), "committed", release7, nonce7
        ).returncode != 0
        assert not list(root.glob(".fpm-guard-marker.*"))

        assert run_python_program(
            publish, str(root), str(committed), "6", release6, nonce6
        ).returncode == 0
        prepared_again = run_python_program(
            prepare, str(root), str(lease), str(armed), str(committed), "7"
        )
        assert prepared_again.returncode == 0, prepared_again.stderr
        reset_attempt = run_python_program(
            reset_program, str(root), str(armed), str(committed), "7", "reset"
        )
        assert reset_attempt.returncode == 0, reset_attempt.stderr
        assert (
            not armed.exists()
            and committed.read_bytes()
            == f"6 {release6} {nonce6}\n".encode("ascii")
            and lease.exists()
        )
        replaced = run_python_program(
            publish, str(root), str(committed), "7", release7, nonce7
        )
        assert replaced.returncode == 0, replaced.stderr
        assert committed.read_bytes() == f"7 {release7} {nonce7}\n".encode("ascii")

        # Simulate death after the atomic marker replacement but before its
        # parent-directory fsync. A normal retry must promote and re-open the
        # exact inode before reporting success; fsync failure must not do so.
        crash_after_replace = publish.replace(
            "    os.replace(temp_path, marker)\n    directory = os.open(",
            "    os.replace(temp_path, marker)\n"
            "    raise SystemExit(99)\n"
            "    directory = os.open(",
            1,
        )
        crash_nonce = "8" * 64
        crashed = run_python_program(
            crash_after_replace,
            str(root),
            str(committed),
            "7",
            release7,
            crash_nonce,
        )
        assert crashed.returncode == 99
        assert committed.read_bytes() == f"7 {release7} {crash_nonce}\n".encode("ascii")
        fsync_failure = publish.replace(
            "            os.fsync(directory)",
            '            raise OSError("injected directory fsync failure")',
            1,
        )
        failed_retry = run_python_program(
            fsync_failure,
            str(root),
            str(committed),
            "7",
            release7,
            crash_nonce,
        )
        assert failed_retry.returncode != 0
        assert committed.read_bytes() == f"7 {release7} {crash_nonce}\n".encode("ascii")
        durable_retry = run_python_program(
            publish, str(root), str(committed), "7", release7, crash_nonce
        )
        assert durable_retry.returncode == 0, durable_retry.stderr

        # A general receiver cleanup must never unlink a guard writer's open
        # temporary. The writer can still publish it; only the guard-lease
        # reset path is allowed to reclaim a killed writer's exact residue.
        cleaner = localize_root_contract(
            heredoc_after(receiver_text, "clean_stale_state_temporaries() {")
        ).replace(
            'Path("/var/lib/shuzijun-sync/state")', f"Path({str(root)!r})"
        )
        writer_temp = root / (".fpm-guard-marker." + "d" * 32)
        writer = os.open(writer_temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.write(writer, f"7 {release7} {nonce7}\n".encode("ascii"))
        os.fsync(writer)
        cleaned = run_python_program(cleaner, str(root))
        assert cleaned.returncode == 0 and writer_temp.exists(), cleaned.stderr
        os.close(writer)
        os.replace(writer_temp, armed)
        assert armed.read_bytes() == f"7 {release7} {nonce7}\n".encode("ascii")

        killed_temp = root / (".fpm-guard-marker." + "e" * 32)
        killed_temp.write_bytes(b"partial")
        killed_temp.chmod(0o600)
        reset_attempt = run_python_program(
            reset_program, str(root), str(armed), str(committed), "7", "reset"
        )
        assert reset_attempt.returncode == 0, reset_attempt.stderr
        assert not killed_temp.exists() and not armed.exists()

        # Resume cleanup reclaims only dead publication temporaries while
        # retaining the exact armed nonce for the next guard process.
        assert run_python_program(
            publish, str(root), str(armed), "7", release7, nonce7
        ).returncode == 0
        preserve_temp = root / (".fpm-guard-marker." + "f" * 32)
        preserve_temp.write_bytes(b"partial")
        preserve_temp.chmod(0o600)
        preserved = run_python_program(
            reset_program, str(root), str(armed), str(committed), "7", "preserve"
        )
        assert preserved.returncode == 0, preserved.stderr
        assert armed.exists() and not preserve_temp.exists()

    with tempfile.TemporaryDirectory(prefix="sync-fpm-guard-link-test-") as raw:
        root = Path(raw).resolve() / "state"
        root.mkdir(mode=0o700)
        lease = root / "fpm-activation-guard.lease"
        armed = root / "fpm-activation-guard-v4.armed"
        committed = root / "fpm-activation-guard-v4.committed"
        external = Path(raw).resolve() / "external"
        external.write_bytes(b"unchanged")
        external.chmod(0o640)
        lease.symlink_to(external)
        rejected = run_python_program(
            prepare, str(root), str(lease), str(armed), str(committed), "7"
        )
        assert rejected.returncode != 0
        assert external.read_bytes() == b"unchanged" and stat_mode(external) == 0o640

        lease.unlink()
        external.write_bytes(b"")
        external.chmod(0o600)
        os.link(external, lease)
        rejected = run_python_program(
            prepare, str(root), str(lease), str(armed), str(committed), "7"
        )
        assert rejected.returncode != 0
        assert external.stat().st_nlink == 2 and stat_mode(external) == 0o600


def test_state_temporary_recovery(receiver_text: str) -> None:
    with tempfile.TemporaryDirectory(prefix="sync-state-temporary-recovery-") as raw:
        root = Path(raw).resolve() / "state"
        root.mkdir(mode=0o700)
        cleaner = localize_root_contract(
            heredoc_after(receiver_text, "clean_stale_state_temporaries() {")
        ).replace(
            'Path("/var/lib/shuzijun-sync/state")', f"Path({str(root)!r})"
        )
        prefixes = {
            ".highest-accepted.": b"7\n",
            ".uploads-transaction.": b"{\"partial\":true}\n",
            ".active-generation.": b"7\n",
            ".active-release-v4.": b"{\"partial\":true}\n",
            ".bootstrap-fpm-commit.": b"partial\n",
        }
        for index, (prefix, payload) in enumerate(prefixes.items(), start=1):
            path = root / f"{prefix}{index:032x}"
            path.write_bytes(payload)
            path.chmod(0o600)
        cleaned = run_python_program(cleaner, str(root))
        assert cleaned.returncode == 0, cleaned.stderr
        assert not list(root.iterdir())

        unknown = root / (".active-release-v4." + "f" * 31 + "x")
        unknown.write_bytes(b"do-not-delete")
        unknown.chmod(0o600)
        rejected = run_python_program(cleaner, str(root))
        assert rejected.returncode != 0 and unknown.read_bytes() == b"do-not-delete"
        unknown.unlink()

        target = Path(raw).resolve() / "outside"
        target.write_bytes(b"unchanged")
        target.chmod(0o600)
        linked = root / (".highest-accepted." + "a" * 32)
        linked.symlink_to(target)
        rejected = run_python_program(cleaner, str(root))
        assert rejected.returncode != 0
        assert linked.is_symlink() and target.read_bytes() == b"unchanged"


def test_sender_generation_state_recovery(sender_text: str) -> None:
    cleaner = localize_root_contract(
        heredoc_after(sender_text, "clean_stale_generation_temporaries() {")
    )
    issue = localize_root_contract(
        heredoc_after(sender_text, "issue_generation() {")
    )
    with tempfile.TemporaryDirectory(prefix="sync-generation-state-test-") as raw:
        root = Path(raw).resolve() / "shuzijun-sync"
        root.mkdir(mode=0o700)
        state = root / "highest-issued-generation"
        state.write_bytes(b"0\n")
        state.chmod(0o600)
        localized_cleaner = cleaner.replace(
            'Path("/var/lib/shuzijun-sync")', f"Path({str(root)!r})"
        )

        stale = root / (".highest-issued." + "a" * 32)
        stale.write_bytes(b"12")
        stale.chmod(0o600)
        cleaned = run_python_program(localized_cleaner, str(root))
        assert cleaned.returncode == 0, cleaned.stderr
        assert not stale.exists()

        unknown = root / ".highest-issued.not-a-token"
        unknown.write_bytes(b"")
        unknown.chmod(0o600)
        rejected = run_python_program(localized_cleaner, str(root))
        assert rejected.returncode != 0 and unknown.exists()
        unknown.unlink()

        outside = Path(raw).resolve() / "outside"
        outside.write_bytes(b"unchanged")
        hostile = root / (".highest-issued." + "b" * 32)
        hostile.symlink_to(outside)
        rejected = run_python_program(localized_cleaner, str(root))
        assert rejected.returncode != 0
        assert hostile.is_symlink() and outside.read_bytes() == b"unchanged"
        hostile.unlink()

        first = run_python_program(issue, str(root), str(state))
        assert first.returncode == 0 and first.stdout == "1\n", first.stderr
        assert state.read_bytes() == b"1\n"

        killed_after_create = issue.replace(
            "try:\n    os.fchmod(temp_descriptor, 0o600)",
            "raise SystemExit(91)\ntry:\n    os.fchmod(temp_descriptor, 0o600)",
            1,
        )
        killed = run_python_program(killed_after_create, str(root), str(state))
        assert killed.returncode == 91
        residues = list(root.glob(".highest-issued.*"))
        assert len(residues) == 1
        assert run_python_program(localized_cleaner, str(root)).returncode == 0
        assert not list(root.glob(".highest-issued.*"))
        assert state.read_bytes() == b"1\n"

        killed_after_replace = issue.replace(
            "    os.replace(temp_path, state_path)\n    os.fsync(directory)",
            "    os.replace(temp_path, state_path)\n"
            "    raise SystemExit(92)\n"
            "    os.fsync(directory)",
            1,
        )
        killed = run_python_program(killed_after_replace, str(root), str(state))
        assert killed.returncode == 92
        assert state.read_bytes() == b"2\n"
        retried = run_python_program(issue, str(root), str(state))
        assert retried.returncode == 0 and retried.stdout == "3\n", retried.stderr
        assert state.read_bytes() == b"3\n"


def test_bootstrap_fpm_commit_recovery(receiver_text: str) -> None:
    bootstrap = localize_linux_rename_noreplace(localize_root_contract(
        heredoc_after(receiver_text, "bootstrap_fpm_guard_state() {")
    ))
    cleaner_template = localize_root_contract(
        heredoc_after(receiver_text, "clean_stale_state_temporaries() {")
    )
    release_id = "b" * 64

    with tempfile.TemporaryDirectory(prefix="sync-bootstrap-commit-test-") as raw:
        base = Path(raw).resolve()

        def make_state(name: str) -> tuple[Path, list[str]]:
            root = base / name
            root.mkdir(mode=0o700)
            accepted = root / "highest-accepted-generation"
            accepted.write_bytes(b"7\n")
            accepted.chmod(0o600)
            arguments = [
                str(root),
                str(root / "fpm-activation-guard.lease"),
                str(root / "fpm-activation-guard-v4.armed"),
                str(root / "fpm-activation-guard-v4.committed"),
                str(accepted),
                "7",
                release_id,
            ]
            return root, arguments

        def clean(root: Path) -> subprocess.CompletedProcess[str]:
            cleaner = cleaner_template.replace(
                'Path("/var/lib/shuzijun-sync/state")', f"Path({str(root)!r})"
            )
            return run_python_program(cleaner, str(root))

        root, arguments = make_state("normal")
        created = run_python_program(bootstrap, *arguments)
        assert created.returncode == 0, created.stderr
        commit = root / "fpm-activation-guard-v4.committed"
        original = commit.read_bytes()
        assert re.fullmatch(
            rb"7 " + release_id.encode("ascii") + rb" [0-9a-f]{64}\n", original
        )
        repeated = run_python_program(bootstrap, *arguments)
        assert repeated.returncode == 0, repeated.stderr
        assert commit.read_bytes() == original

        # Existing exact bytes are not accepted if their parent-directory
        # durability promotion fails.
        prefix, separator, suffix = bootstrap.rpartition("    os.fsync(directory)")
        assert separator
        exact_fsync_failure = (
            prefix
            + '    raise OSError("injected bootstrap directory fsync failure")'
            + suffix
        )
        failed = run_python_program(exact_fsync_failure, *arguments)
        assert failed.returncode != 0 and commit.read_bytes() == original

        create_needle = (
            "    descriptor = os.open(\n"
            "        temporary,\n"
            "        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,\n"
            "        0o600,\n"
            "    )\n"
            "    try:"
        )
        create_replacement = create_needle.replace(
            "    try:", "    raise SystemExit(91)\n    try:"
        )
        crash_programs = [
            bootstrap.replace(create_needle, create_replacement, 1),
            bootstrap.replace(
                "            written = os.write(descriptor, view)\n"
                "            if written <= 0:",
                "            written = os.write(descriptor, view[:1])\n"
                "            raise SystemExit(92)\n"
                "            if written <= 0:",
                1,
            ),
            bootstrap.replace(
                "        os.fsync(descriptor)\n        temporary_meta",
                "        raise SystemExit(93)\n"
                "        os.fsync(descriptor)\n        temporary_meta",
                1,
            ),
            bootstrap.replace(
                "            raise OSError(error, os.strerror(error))\n    finally:",
                "            raise OSError(error, os.strerror(error))\n"
                "        raise SystemExit(94)\n"
                "    finally:",
                1,
            ),
        ]
        for index, program in enumerate(crash_programs, start=1):
            assert program != bootstrap
            crash_root, crash_arguments = make_state(f"crash-{index}")
            crashed = run_python_program(program, *crash_arguments)
            assert crashed.returncode == 90 + index, crashed.stderr
            cleaned = clean(crash_root)
            assert cleaned.returncode == 0, cleaned.stderr
            resumed = run_python_program(bootstrap, *crash_arguments)
            assert resumed.returncode == 0, resumed.stderr
            assert not list(crash_root.glob(".bootstrap-fpm-commit.*"))

        malformed_root, malformed_arguments = make_state("malformed")
        malformed = malformed_root / "fpm-activation-guard-v4.committed"
        malformed.write_bytes(b"partial")
        malformed.chmod(0o600)
        rejected = run_python_program(bootstrap, *malformed_arguments)
        assert rejected.returncode != 0 and malformed.read_bytes() == b"partial"

        locked_root, locked_arguments = make_state("locked")
        locked_lease = locked_root / "fpm-activation-guard.lease"
        locked_lease.write_bytes(b"")
        locked_lease.chmod(0o600)
        lease_descriptor = os.open(locked_lease, os.O_RDWR)
        fcntl.flock(lease_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        rejected = run_python_program(bootstrap, *locked_arguments)
        assert rejected.returncode != 0
        assert not (locked_root / "fpm-activation-guard-v4.committed").exists()
        os.close(lease_descriptor)


def test_commit_ready_three_state(receiver_text: str) -> None:
    classifier = localize_root_contract(
        heredoc_after(receiver_text, "classify_fpm_guard_commit_marker() {")
    )
    nonce = "a" * 64
    release_id = "b" * 64
    prior_release_id = "c" * 64
    prior_nonce = "6" * 64
    with tempfile.TemporaryDirectory(prefix="sync-commit-three-state-") as raw:
        root = Path(raw).resolve() / "state"
        root.mkdir(mode=0o700)
        commit = root / "fpm-activation-guard-v4.committed"

        def classify() -> subprocess.CompletedProcess[str]:
            return run_python_program(
                classifier, str(root), str(commit), "7", "6", release_id, nonce
            )

        assert classify().returncode == 2, "an exact missing marker is uncommitted"
        commit.write_text(
            f"6 {prior_release_id} {prior_nonce}\n", encoding="ascii"
        )
        commit.chmod(0o600)
        assert classify().returncode == 2, "the exact prior commit is uncommitted"
        commit.write_text(f"7 {release_id} {nonce}\n", encoding="ascii")
        assert classify().returncode == 0, "the activation nonce binds the commit"

        commit.write_text(f"7 {release_id} {'d' * 64}\n", encoding="ascii")
        assert classify().returncode == 1, "same-generation old nonce must not replay"
        commit.write_text(f"7 {'d' * 64} {nonce}\n", encoding="ascii")
        assert classify().returncode == 1, "wrong release id must not authorize activation"
        commit.write_text("malformed\n", encoding="ascii")
        assert classify().returncode == 1
        commit.chmod(0o644)
        assert classify().returncode == 1
        commit.unlink()
        outside = Path(raw).resolve() / "outside"
        outside.write_text(
            f"6 {prior_release_id} {prior_nonce}\n", encoding="ascii"
        )
        outside.chmod(0o600)
        commit.symlink_to(outside)
        assert classify().returncode == 1, "symlink uncertainty is never absence"
        commit.unlink()
        os.link(outside, commit)
        assert classify().returncode == 1, "hard-linked state is never absence"

    rollback = shell_function(receiver_text, "rollback_incomplete_transaction")

    def rollback_status(classifier_status: int) -> tuple[int, bool]:
        with tempfile.TemporaryDirectory(prefix="sync-commit-rollback-decision-") as raw:
            marker = Path(raw) / "rollback-called"
            harness = (
                "set -euo pipefail\n"
                + rollback
                + "\nmanage_uploads_transaction() {\n"
                + "  case \"$1\" in inspect) printf '7 6 commit-ready /backup\\n' ;; "
                + "rollback-media) : > \"$ROLLED\"; printf 'clean\\n' ;; "
                + "*) return 1 ;; esac\n}\n"
                + "classify_commit_ready_transaction() { return \"$CLASSIFIER_STATUS\"; }\n"
                + "isolate_failed_fpm() { return 0; }\n"
                + "restore_database_from_backup() { return 0; }\n"
                + "verify_webroot_security() { return 0; }\n"
                + "validate_database_markers() { return 0; }\n"
                + "set +e\nrollback_incomplete_transaction\nstatus=$?\nset -e\n"
                + "exit \"$status\"\n"
            )
            result = subprocess.run(
                ["/bin/bash", "-c", harness, "rollback-decision-test"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={
                    "PATH": "/usr/bin:/bin",
                    "CLASSIFIER_STATUS": str(classifier_status),
                    "ROLLED": str(marker),
                },
                check=False,
            )
            return result.returncode, marker.exists()

    assert rollback_status(0) == (2, False), "valid commit is forward-only"
    assert rollback_status(2) == (0, True), "proven uncommitted state may roll back"
    assert rollback_status(1) == (3, False), "I/O/format uncertainty must be retained"
    assert rollback_status(124) == (3, False), "timeout must never become rollback"


def test_fpm_guard_runtime_decisions(receiver_text: str) -> None:
    function_start = receiver_text.index("watch_fpm_activation_guard() {")
    body_start = receiver_text.index('    exec 6<>"$lease"', function_start)
    body_end = receiver_text.index("\n}\n", body_start)
    runtime_body = receiver_text[body_start:body_end]

    def exercise(
        root: Path,
        *,
        lease_busy: bool,
        initial_commit: bool,
        commit_on_ready: bool,
        isolation_succeeds: bool = True,
        nonblocking_flock_error: int = 0,
    ) -> subprocess.CompletedProcess[str]:
        root.mkdir()
        lease = root / "lease"
        lease.write_bytes(b"")
        committed = root / "committed"
        if initial_commit:
            committed.write_text("7\n", encoding="ascii")
        harness = (
            "set -euo pipefail\n"
            "stat() { printf '%s\\n' '0:0:1:600'; }\n"
            "manage_uploads_transaction() { "
            "[[ \"$1\" == activation-release-id && \"$2\" == 7 ]] || return 1; "
            "printf 'b%.0s' {1..64}; printf '\\n'; }\n"
            "publish_fpm_guard_marker() { printf '%s\\n' \"$2\" > \"$1\"; }\n"
            "read_accepted_generation() { printf '7\\n'; }\n"
            "new_fpm_activation_nonce() { printf 'a%.0s' {1..64}; printf '\\n'; }\n"
            "validate_fpm_guard_commit_matches_accepted() { "
            "[[ -f \"$COMMITTED\" && \"$(cat \"$COMMITTED\")\" == 7 ]]; }\n"
            "flock() { if [[ \"${1:-}\" == -n ]]; then "
            "if (( NONBLOCKING_FLOCK_ERROR != 0 )); then "
            "return \"$NONBLOCKING_FLOCK_ERROR\"; fi; "
            "if [[ \"$LEASE_BUSY\" == 1 ]]; then return 99; fi; "
            "return 0; else return 0; fi; }\n"
            "systemd-notify() { : > \"$READY\"; "
            "if [[ \"$COMMIT_ON_READY\" == 1 ]]; then "
            "printf '7\\n' > \"$COMMITTED\"; fi; }\n"
            "isolate_fpm_from_activation_guard() { : > \"$ISOLATED\"; "
            "[[ \"$ISOLATION_SUCCEEDS\" == 1 ]]; }\n"
            "watch_fixture() {\n"
            + runtime_body
            + "\n}\n"
            "lease=$1\narmed=$2\ncommitted=$3\n"
            "READY=$4\nISOLATED=$5\nCOMMITTED=$3\n"
            "LEASE_BUSY=$6\nCOMMIT_ON_READY=$7\nISOLATION_SUCCEEDS=$8\n"
            "NONBLOCKING_FLOCK_ERROR=$9\n"
            "set +e\nwatch_fixture\nstatus=$?\nset -e\nexit \"$status\"\n"
        )
        return subprocess.run(
            [
                "/bin/bash",
                "-c",
                harness,
                "guard-runtime-test",
                str(lease),
                str(root / "armed"),
                str(committed),
                str(root / "ready"),
                str(root / "isolated"),
                "1" if lease_busy else "0",
                "1" if commit_on_ready else "0",
                "1" if isolation_succeeds else "0",
                str(nonblocking_flock_error),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    with tempfile.TemporaryDirectory(prefix="sync-fpm-guard-runtime-test-") as raw:
        root = Path(raw).resolve()

        boot_committed = exercise(
            root / "boot-committed",
            lease_busy=False,
            initial_commit=True,
            commit_on_ready=False,
        )
        assert boot_committed.returncode == 0
        assert (root / "boot-committed" / "ready").exists()
        assert not (root / "boot-committed" / "isolated").exists()

        boot_uncommitted = exercise(
            root / "boot-uncommitted",
            lease_busy=False,
            initial_commit=False,
            commit_on_ready=False,
        )
        assert boot_uncommitted.returncode == 77
        assert not (root / "boot-uncommitted" / "ready").exists()
        assert (root / "boot-uncommitted" / "isolated").exists()

        live_committed = exercise(
            root / "live-committed",
            lease_busy=True,
            initial_commit=False,
            commit_on_ready=True,
        )
        assert live_committed.returncode == 0
        assert (root / "live-committed" / "ready").exists()
        assert not (root / "live-committed" / "isolated").exists()

        # Models the independent watcher acquiring the lease after the receiver
        # is killed: READY was already sent, but no commit means isolation and a
        # failed dependency rather than a successful committed completion.
        killed_uncommitted = exercise(
            root / "killed-uncommitted",
            lease_busy=True,
            initial_commit=False,
            commit_on_ready=False,
        )
        assert killed_uncommitted.returncode == 77
        assert (root / "killed-uncommitted" / "ready").exists()
        assert (root / "killed-uncommitted" / "isolated").exists()

        isolation_failure = exercise(
            root / "isolation-failure",
            lease_busy=False,
            initial_commit=False,
            commit_on_ready=False,
            isolation_succeeds=False,
        )
        assert isolation_failure.returncode == 1

        flock_failure = exercise(
            root / "flock-failure",
            lease_busy=False,
            initial_commit=False,
            commit_on_ready=False,
            nonblocking_flock_error=75,
        )
        assert flock_failure.returncode == 1
        assert not (root / "flock-failure" / "ready").exists()
        assert not (root / "flock-failure" / "armed").exists()
        assert not (root / "flock-failure" / "isolated").exists()


def test_fpm_guard_stop_finalizer(receiver_text: str) -> None:
    function_start = receiver_text.index("finalize_fpm_activation_guard() {")
    body_start = receiver_text.index(
        "    if validate_fpm_guard_runtime_context", function_start
    )
    body_end = receiver_text.index("\n}\n", body_start)
    finalizer_body = receiver_text[body_start:body_end]

    def exercise(
        root: Path,
        *,
        committed_present: bool,
        isolation_succeeds: bool,
        context_is_valid: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        root.mkdir()
        committed = root / "committed"
        lease = root / "lease"
        lease.write_bytes(b"")
        if committed_present:
            committed.write_text("7\n", encoding="ascii")
        harness = (
            "set -euo pipefail\n"
            "validate_fpm_guard_runtime_context() { "
            "[[ \"$CONTEXT_IS_VALID\" == 1 ]]; }\n"
            "stat() { printf '%s\\n' '0:0:1:600'; }\n"
            "flock() { return 0; }\n"
            "validate_fpm_guard_commit_matches_accepted() { "
            "[[ -f \"$COMMITTED\" && \"$(cat \"$COMMITTED\")\" == 7 ]]; }\n"
            "isolate_fpm_from_activation_guard() { : > \"$ISOLATED\"; "
            "[[ \"$ISOLATION_SUCCEEDS\" == 1 ]]; }\n"
            "finalizer_fixture() {\n"
            "local committed=$1\n"
            + finalizer_body
            + "\n}\n"
            "COMMITTED=$1\nISOLATED=$2\nISOLATION_SUCCEEDS=$3\n"
            "CONTEXT_IS_VALID=$4\nFPM_GUARD_LEASE=$5\n"
            "set +e\nfinalizer_fixture \"$COMMITTED\"\nstatus=$?\nset -e\n"
            "exit \"$status\"\n"
        )
        return subprocess.run(
            [
                "/bin/bash",
                "-c",
                harness,
                "guard-finalizer-test",
                str(committed),
                str(root / "isolated"),
                "1" if isolation_succeeds else "0",
                "1" if context_is_valid else "0",
                str(lease),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    with tempfile.TemporaryDirectory(prefix="sync-fpm-guard-finalizer-test-") as raw:
        root = Path(raw).resolve()

        committed = exercise(
            root / "committed", committed_present=True, isolation_succeeds=True
        )
        assert committed.returncode == 0, committed.stderr
        assert not (root / "committed" / "isolated").exists()

        timeout_isolated = exercise(
            root / "timeout-isolated",
            committed_present=False,
            isolation_succeeds=True,
        )
        assert timeout_isolated.returncode == 0, timeout_isolated.stderr
        assert (root / "timeout-isolated" / "isolated").exists()

        isolation_failure = exercise(
            root / "isolation-failure",
            committed_present=False,
            isolation_succeeds=False,
        )
        assert isolation_failure.returncode == 1
        assert (root / "isolation-failure" / "isolated").exists()

        invalid_context = exercise(
            root / "invalid-context",
            committed_present=True,
            isolation_succeeds=True,
            context_is_valid=False,
        )
        # A context failure proves an otherwise valid-looking commit cannot
        # bypass the fail-closed stop hook.
        assert invalid_context.returncode == 0, invalid_context.stderr
        assert (root / "invalid-context" / "isolated").exists()


def test_receiver_condition_context_failure_propagation(receiver_text: str) -> None:
    """Critical helpers must stay fail-closed when Bash disables errexit in `if`."""

    runtime_context = shell_function(receiver_text, "validate_fpm_guard_runtime_context")
    runtime_harness = (
        "set -euo pipefail\n"
        + runtime_context
        + "\nTEST_CALLS=0\nSELF=/fixture/receiver\n"
        + "test() { TEST_CALLS=$((TEST_CALLS + 1)); "
        + "if [[ $TEST_CALLS -eq 1 ]]; then return 1; fi; return 0; }\n"
        + "realpath() { printf '%s\\n' \"${@: -1}\"; }\n"
        + "stat() { printf '0:0:1:755\\n'; }\n"
        + "validate_sync_state_roots() { return 0; }\n"
        + "if validate_fpm_guard_runtime_context; then exit 0; fi\nexit 23\n"
    )
    runtime = subprocess.run(
        ["/bin/bash", "-c", runtime_harness, "/fixture/receiver"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert runtime.returncode == 23, runtime.stderr

    state_roots = shell_function(receiver_text, "validate_sync_state_roots")
    state_harness = (
        "set -euo pipefail\n"
        + state_roots
        + "\nTEST_CALLS=0\n"
        + "test() { TEST_CALLS=$((TEST_CALLS + 1)); "
        + "if [[ $TEST_CALLS -eq 1 ]]; then return 1; fi; return 0; }\n"
        + "realpath() { printf '%s\\n' \"${@: -1}\"; }\n"
        + "stat() { printf '0:0:700\\n'; }\n"
        + "SYNC_ROOT=/state\nCLAIM_ROOT=/claims\nSTATE_ROOT=/state/meta\n"
        + "if validate_sync_state_roots; then exit 0; fi\nexit 24\n"
    )
    state = subprocess.run(
        ["/bin/bash", "-c", state_harness, "state-roots-test"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert state.returncode == 24, state.stderr

    database_markers = shell_function(receiver_text, "validate_database_markers")
    database_harness = (
        "set -euo pipefail\n"
        + database_markers
        + "\nSITE=/fixture/site\ncd() { return 0; }\n"
        + "wp() {\n"
        + "  if [[ \"$1 $2\" == 'db check' ]]; then return 1; fi\n"
        + "  if [[ \"$1 $2 $3\" == 'option get siteurl' ]]; then "
        + "printf 'https://www.shuzijun.com.cn\\n'; return 0; fi\n"
        + "  if [[ \"$1 $2 $3\" == 'option get home' ]]; then "
        + "printf 'https://www.shuzijun.com.cn\\n'; return 0; fi\n"
        + "  if [[ \"$1 $2 $4\" == 'post get --field=post_type' ]]; then "
        + "printf 'portfolio\\n'; return 0; fi\n"
        + "  if [[ \"$1 $2 $4\" == 'post get --field=post_status' ]]; then "
        + "printf 'publish\\n'; return 0; fi\n"
        + "  return 1\n}\n"
        + "if validate_database_markers; then exit 0; fi\nexit 25\n"
    )
    database = subprocess.run(
        ["/bin/bash", "-c", database_harness, "database-markers-test"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert database.returncode == 25, database.stderr

    correct_output_then_failure = database_harness.replace(
        "if [[ \"$1 $2\" == 'db check' ]]; then return 1; fi",
        "if [[ \"$1 $2\" == 'db check' ]]; then return 0; fi",
    ).replace(
        "printf 'https://www.shuzijun.com.cn\\n'; return 0; fi",
        "printf 'https://www.shuzijun.com.cn\\n'; return 124; fi",
        1,
    )
    output_failure = subprocess.run(
        ["/bin/bash", "-c", correct_output_then_failure, "database-markers-test"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert output_failure.returncode == 25, (
        "expected output followed by a timeout/nonzero status must fail closed"
    )

    uncommitted_gate = shell_function(
        receiver_text, "assert_fpm_guard_uncommitted_for_generation"
    )

    def run_uncommitted_gate(
        *, marker_ok: bool, inspect_value: str = "7 6 accepted /var/backups/backup"
    ) -> subprocess.CompletedProcess[str]:
        harness = (
            "set -euo pipefail\n"
            + uncommitted_gate
            + "\nread_accepted_generation() { printf '7\\n'; }\n"
            + "manage_uploads_transaction() {\n"
            + "  case \"$1\" in inspect) printf '%s\\n' \"$INSPECT\" ;; "
            + "validate-active) printf '6\\n' ;; "
            + "stable-release-id) printf 'b%.0s' {1..64}; printf '\\n' ;; "
            + "*) return 1 ;; esac\n}\n"
            + "read_fpm_guard_marker() { [[ \"$MARKER_OK\" == 1 ]] || return 1; "
            + "printf 'b%.0s' {1..64}; printf ' '; printf 'a%.0s' {1..64}; printf '\\n'; }\n"
            + "FPM_GUARD_COMMIT=/state/committed\n"
            + "if assert_fpm_guard_uncommitted_for_generation 7; then exit 0; fi\n"
            + "exit 27\n"
        )
        return subprocess.run(
            ["/bin/bash", "-c", harness, "uncommitted-gate-test"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={
                "PATH": "/usr/bin:/bin",
                "MARKER_OK": "1" if marker_ok else "0",
                "INSPECT": inspect_value,
            },
            check=False,
        )

    assert run_uncommitted_gate(marker_ok=True).returncode == 0
    assert run_uncommitted_gate(marker_ok=False).returncode == 27
    assert run_uncommitted_gate(
        marker_ok=True, inspect_value="7 6 corrupt /var/backups/backup"
    ).returncode == 27

    commit_guard = shell_function(receiver_text, "commit_fpm_activation_guard")
    with tempfile.TemporaryDirectory(prefix="sync-commit-failure-context-") as raw:
        marker = Path(raw).resolve() / "continued-after-publish"
        commit_harness = (
            "set -euo pipefail\n"
            + commit_guard
            + "\nread_accepted_generation() { printf '7\\n'; }\n"
            + "validate_fpm_guard_marker() { return 0; }\n"
            + "publish_fpm_guard_marker() { return 1; }\n"
            + "flock() { : > \"$CONTINUED\"; return 0; }\n"
            + "systemctl() { printf 'success\\n'; }\n"
            + "validate_fpm_guard_commit_matches_accepted() { return 0; }\n"
            + "verify_fpm_ready() { return 0; }\n"
            + "CONTINUED=$1\nFPM_GUARD_ARMED=/state/armed\n"
            + "FPM_GUARD_COMMIT=/state/committed\n"
            + "FPM_ACTIVATION_RELEASE_ID=$(printf 'b%.0s' {1..64})\n"
            + "FPM_ACTIVATION_NONCE=$(printf 'a%.0s' {1..64})\nPOST_COMMIT=0\n"
            + "FPM_GUARD_UNIT=shuzijun-sync-fpm-guard.service\nexec 6<>/dev/null\n"
            + "if commit_fpm_activation_guard 7; then exit 0; fi\nexit 26\n"
        )
        commit = subprocess.run(
            ["/bin/bash", "-c", commit_harness, "commit-context-test", str(marker)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        assert commit.returncode == 26, commit.stderr
        assert not marker.exists(), "a failed commit publication must stop the function immediately"

    assert "! validate_fpm_guard_commit_matches_accepted" not in receiver_text
    assert "if validate_fpm_guard_commit_matches_accepted; then" in receiver_text

    unit_file_state = shell_function(receiver_text, "read_unit_file_state")

    def run_unit_file_state(
        output: str, status: int, expected: str
    ) -> subprocess.CompletedProcess[str]:
        harness = (
            "set -euo pipefail\n"
            + unit_file_state
            + "\nsystemctl() { printf '%s\\n' \"$STATE_OUTPUT\"; "
            + "return \"$STATE_STATUS\"; }\n"
            + "value=$(read_unit_file_state fixture.service) || exit 41\n"
            + "[[ \"$value\" == \"$EXPECTED\" ]] || exit 42\n"
        )
        return subprocess.run(
            ["/bin/bash", "-c", harness, "unit-file-state-test"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={
                "PATH": "/usr/bin:/bin",
                "STATE_OUTPUT": output,
                "STATE_STATUS": str(status),
                "EXPECTED": expected,
            },
            check=False,
        )

    for output, status in (("enabled", 0), ("disabled", 1), ("masked", 1)):
        assert run_unit_file_state(output, status, output).returncode == 0
    for output, status in (
        ("masked", 124),
        ("disabled", 124),
        ("enabled", 124),
        ("masked", 0),
        ("disabled", 0),
    ):
        assert run_unit_file_state(output, status, output).returncode == 41

    baseline = shell_function(receiver_text, "ensure_receiver_baseline")
    plausible_guard_harness = (
        "set -euo pipefail\n"
        + baseline
        + "\nmanage_uploads_transaction() { printf '6\\n'; }\n"
        + "read_accepted_generation() { printf '7\\n'; }\n"
        + "verify_fpm_ready() { return 1; }\n"
        + "isolate_failed_fpm() { return 0; }\n"
        + "systemctl() {\n"
        + "  case \"$*\" in *ActiveState*) printf 'failed\\n'; return 0 ;; "
        + "*Result*) printf 'exit-code\\n'; return 0 ;; "
        + "*ExecMainStatus*) printf '77\\n'; return 124 ;; esac\n"
        + "  return 1\n}\n"
        + "if ensure_receiver_baseline; then exit 0; fi\nexit 43\n"
    )
    plausible_guard = subprocess.run(
        ["/bin/bash", "-c", plausible_guard_harness, "baseline-status-test"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={"PATH": "/usr/bin:/bin"},
        check=False,
    )
    assert plausible_guard.returncode == 43, (
        "ExecMainStatus=77 followed by timeout/nonzero must fail closed"
    )

    isolate_body = shell_function(receiver_text, "isolate_failed_fpm")
    validate_unit_body = shell_function(receiver_text, "validate_fpm_guard_unit")
    arm_body = shell_function(receiver_text, "arm_fpm_activation_guard")
    assert 'read_unit_file_state "$FPM_SERVICE"' in isolate_body
    assert 'read_unit_file_state "$FPM_GUARD_UNIT"' in validate_unit_body
    assert 'read_unit_file_state "$FPM_GUARD_UNIT"' in arm_body


def test_receiver_external_deadline_contract(receiver_text: str) -> None:
    for wrapper, deadline, binary in (
        ("systemctl", "20 5", "/usr/bin/systemctl"),
        ("wp", "300 10", "/usr/bin/wp"),
        ("nginx", "20 5", "/usr/sbin/nginx"),
        ("gzip", "300 10", "/usr/bin/gzip"),
        ("sync", "120 10", "/usr/bin/sync"),
    ):
        body = shell_function(receiver_text, wrapper)
        assert f"run_with_deadline {deadline} {binary}" in body

    deadline_runner = shell_function(receiver_text, "run_with_deadline")
    assert "start_new_session=True" in deadline_runner
    assert "os.killpg(child.pid, number)" in deadline_runner
    assert "stop_group(signal.SIGTERM)" in deadline_runner
    assert "signal_group(signal.SIGKILL)" in deadline_runner
    assert "signal.signal(number, reinforce_cleanup)" in deadline_runner
    assert "except InterruptedError:" in deadline_runner
    assert "/proc/self/fd/19" in deadline_runner
    assert "19<<'PY'" in deadline_runner
    assert "pass_fds = (9,)" in deadline_runner

    for function_name, deadline in (
        ("prepare_database_sql", "30m"),
        ("ingest_signed_payload", "8h"),
        ("prepare_backup_destination", "5m"),
        ("retire_backup_history", "5m"),
        ("store_backup_archive", "5m"),
        ("manage_uploads_transaction", "30m"),
        ("prepare_rollback_sql", "5m"),
        ("remove_rollback_sql", "5m"),
        ("remove_claim_tree", "30m"),
    ):
        start = receiver_text.index(f"{function_name}() {{")
        if function_name == "remove_claim_tree":
            end = receiver_text.index("\n}\n", start) + 3
        else:
            python_start = receiver_text.index("<<'PY'", start)
            end = receiver_text.index("\nPY\n}", python_start) + 5
        body = receiver_text[start:end]
        assert "/usr/bin/timeout --signal=TERM" in body
        if function_name == "manage_uploads_transaction":
            assert "local deadline=30m" in body
        else:
            assert f" {deadline} " in body
        assert "--foreground" not in body

    for function_name in (
        "persist_new_claim",
        "publish_backup_destination",
        "accept_generation",
        "prepare_fpm_guard_state",
        "publish_fpm_guard_marker",
        "read_fpm_guard_marker",
        "bootstrap_fpm_guard_state",
    ):
        assert "run_with_deadline 5 2" in shell_function(receiver_text, function_name)

    for function_name in (
        "isolate_failed_fpm",
        "isolate_fpm_from_activation_guard",
        "arm_fpm_activation_guard",
    ):
        body = shell_function(receiver_text, function_name)
        assert "systemctl is-active" not in body, (
            "an arbitrary nonzero is-active status must not prove isolation"
        )

    if sys.platform != "linux" or not Path("/usr/bin/timeout").is_file():
        return

    with tempfile.TemporaryDirectory(prefix="sync-receiver-timeout-test-") as raw:
        temp = Path(raw)
        nested_effect = temp / "nested-helper-ran"
        nested_harness = (
            "set -euo pipefail\n"
            + deadline_runner
            + "\nrun_with_deadline 2 1 /usr/bin/python3 -I /proc/self/fd/9 "
            + '"$EFFECT" expected 9<<\'INNER\'\n'
            + "import pathlib\nimport sys\n"
            + "assert sys.argv[2] == 'expected'\n"
            + "pathlib.Path(sys.argv[1]).write_text('executed\\n', encoding='ascii')\n"
            + "print('inner-program-executed')\nINNER\n"
        )
        nested = subprocess.run(
            ["/bin/bash", "-c", nested_harness, "receiver-nested-fd-test"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin", "EFFECT": str(nested_effect)},
            timeout=4,
            check=False,
        )
        assert nested.returncode == 0, nested.stderr
        assert nested.stdout == "inner-program-executed\n"
        assert nested_effect.read_text(encoding="ascii") == "executed\n"

        # A second signal during grace-period teardown must not unwind the
        # supervisor before it SIGKILLs and reaps the signal-resistant group.
        deadline_program_start = deadline_runner.index("19<<'PY'\n") + len(
            "19<<'PY'\n"
        )
        deadline_program_end = deadline_runner.rindex("\nPY\n")
        deadline_program = temp / "deadline-supervisor.py"
        deadline_program.write_text(
            deadline_runner[deadline_program_start:deadline_program_end] + "\n",
            encoding="utf-8",
        )
        resistant = temp / "signal-resistant-group.py"
        resistant.write_text(
            "import os, pathlib, signal, subprocess, sys, time\n"
            "for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):\n"
            "    signal.signal(number, signal.SIG_IGN)\n"
            "grandchild = subprocess.Popen([\n"
            "    '/bin/bash', '-c',\n"
            "    \"trap '' TERM INT HUP; while :; do sleep 1; done\",\n"
            "])\n"
            "pathlib.Path(sys.argv[1]).write_text(\n"
            "    f'{os.getpid()} {grandchild.pid}\\n', encoding='ascii'\n"
            ")\n"
            "while True: time.sleep(1)\n",
            encoding="utf-8",
        )

        def process_is_live(pid: int) -> bool:
            status = Path(f"/proc/{pid}/stat")
            if not status.exists():
                return False
            fields = status.read_text(encoding="ascii").split()
            return len(fields) > 2 and fields[2] != "Z"

        for followup in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            pid_record = temp / f"signal-group-{followup}.pids"
            supervisor = subprocess.Popen(
                [
                    "/usr/bin/python3", "-I", str(deadline_program),
                    "10", "1", "/usr/bin/python3", "-I", str(resistant),
                    str(pid_record),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env={"PATH": "/usr/bin:/bin"},
            )
            try:
                record_deadline = time.monotonic() + 2
                while time.monotonic() < record_deadline and not pid_record.exists():
                    time.sleep(0.02)
                assert pid_record.exists()
                child_pid, grandchild_pid = map(
                    int, pid_record.read_text(encoding="ascii").split()
                )
                os.kill(supervisor.pid, signal.SIGTERM)
                time.sleep(0.05)
                os.kill(supervisor.pid, followup)
                stdout, stderr = supervisor.communicate(timeout=4)
                assert supervisor.returncode == 128 + signal.SIGTERM, (
                    followup, supervisor.returncode, stdout, stderr
                )
                process_deadline = time.monotonic() + 2
                while time.monotonic() < process_deadline and any(
                    process_is_live(pid) for pid in (child_pid, grandchild_pid)
                ):
                    time.sleep(0.02)
                assert not process_is_live(child_pid)
                assert not process_is_live(grandchild_pid)
            finally:
                if supervisor.poll() is None:
                    supervisor.kill()
                    supervisor.wait(timeout=2)

        helper = temp / "stall-service-manager"
        pid_file = temp / "grandchild.pid"
        helper.write_text(
            "#!/bin/bash\n"
            "( trap '' TERM; while :; do sleep 1; done ) &\n"
            "child=$!\n"
            "printf '%s\\n' \"$child\" > \"$PID_FILE\"\n"
            "wait \"$child\"\n",
            encoding="utf-8",
        )
        helper.chmod(0o755)
        bounded_runner = deadline_runner
        bounded = shell_function(receiver_text, "systemctl").replace(
            "run_with_deadline 20 5 /usr/bin/systemctl",
            'run_with_deadline 1 1 "$HELPER"',
        )
        harness = (
            "set -euo pipefail\n"
            + bounded_runner
            + "\n"
            + bounded
            + "\nif systemctl show fixture.service; then exit 0; fi\nexit 32\n"
        )
        started = time.monotonic()
        result = subprocess.run(
            ["/bin/bash", "-c", harness, "receiver-timeout-test"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={
                "PATH": "/usr/bin:/bin",
                "HELPER": str(helper),
                "PID_FILE": str(pid_file),
            },
            timeout=4,
            check=False,
        )
        assert result.returncode == 32, result.stderr
        assert time.monotonic() - started < 3
        child = int(pid_file.read_text(encoding="ascii"))
        for _ in range(50):
            try:
                os.kill(child, 0)
            except ProcessLookupError:
                break
            time.sleep(0.02)
        else:
            raise AssertionError("timeout left a receiver service-manager grandchild alive")

    ingest_start = receiver_text.index("ingest_signed_payload() {")
    ingest_end = receiver_text.index("\nPY\n}\n", ingest_start) + len("\nPY\n}\n")
    ingest = receiver_text[ingest_start:ingest_end].replace(
        "--kill-after=10s 8h", "--kill-after=0.1s 0.2s"
    )
    with tempfile.TemporaryDirectory(prefix="sync-receiver-ingest-timeout-") as raw:
        claim = Path(raw).resolve() / "claim"
        claim.mkdir(mode=0o700)
        payload = b"x"
        manifest = {
            "files": [
                {
                    "path": "shuzijun-sync.sql.gz",
                    "sha256": hashlib.sha256(payload).hexdigest(),
                    "size": len(payload),
                }
            ],
            "generation": 7,
            "version": 2,
        }
        (claim / "shuzijun-sync-manifest.json").write_text(
            json.dumps(
                manifest, ensure_ascii=True, separators=(",", ":"), sort_keys=True
            )
            + "\n",
            encoding="ascii",
        )
        stalled_writer = subprocess.Popen(
            ["/bin/bash", "-c", "sleep 10"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=False,
            env={"PATH": "/usr/bin:/bin"},
        )
        try:
            harness = (
                "set -euo pipefail\n"
                + ingest
                + "\nif ingest_signed_payload \"$1\"; then exit 0; fi\nexit 35\n"
            )
            started = time.monotonic()
            stalled = subprocess.run(
                ["/bin/bash", "-c", harness, "receiver-ingest-timeout", str(claim)],
                stdin=stalled_writer.stdout,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={"PATH": "/usr/bin:/bin"},
                timeout=3,
                check=False,
            )
        finally:
            if stalled_writer.stdout is not None:
                stalled_writer.stdout.close()
            stalled_writer.terminate()
            try:
                stalled_writer.wait(timeout=1)
            except subprocess.TimeoutExpired:
                stalled_writer.kill()
                stalled_writer.wait(timeout=1)
        assert stalled.returncode == 35, stalled.stderr.decode("utf-8", errors="replace")
        assert time.monotonic() - started < 2


def test_rollback_sql_cleanup_on_cd_failure(receiver_text: str) -> None:
    restore = shell_function(receiver_text, "restore_database_from_backup")
    harness = (
        "set -euo pipefail\n"
        + restore
        + "\nROLLBACK_SQL=\nSITE=/missing-site\nCLEANED=$1\nWP_RAN=$2\n"
        + "allocate_rollback_sql() { ROLLBACK_SQL=/state/.rollback-database.123; }\n"
        + "prepare_rollback_sql() { [[ \"$2\" == \"$ROLLBACK_SQL\" ]]; }\n"
        + "cd() { return 1; }\n"
        + "wp() { : > \"$WP_RAN\"; return 0; }\n"
        + "validate_database_markers() { return 0; }\n"
        + "remove_rollback_sql() { printf '%s\\n' \"$1\" > \"$CLEANED\"; return 0; }\n"
        + "if restore_database_from_backup /backup; then exit 40; fi\n"
        + "[[ -z \"$ROLLBACK_SQL\" && ! -e \"$WP_RAN\" ]] || exit 41\n"
        + "[[ \"$(cat \"$CLEANED\")\" == /state/.rollback-database.123 ]] || exit 42\n"
    )
    with tempfile.TemporaryDirectory(prefix="sync-rollback-cleanup-test-") as raw:
        root = Path(raw)
        result = subprocess.run(
            [
                "/bin/bash",
                "-c",
                harness,
                "rollback-cleanup-test",
                str(root / "cleaned"),
                str(root / "wp-ran"),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin"},
            check=False,
        )
        assert result.returncode == 0, result.stderr
    finish = shell_function(receiver_text, "finish_receiver")
    assert 'if [[ -n "$ROLLBACK_SQL" ]]' in finish
    assert 'remove_rollback_sql "$ROLLBACK_SQL"' in finish

    stale_program = localize_root_contract(
        heredoc_after(receiver_text, "clean_stale_rollback_sql() {")
    )
    with tempfile.TemporaryDirectory(prefix="sync-stale-rollback-sql-") as raw:
        state = Path(raw).resolve() / "state"
        state.mkdir(mode=0o700)
        stale = state / ".rollback-database.12345"
        stale.write_bytes(b"plaintext rollback SQL")
        stale.chmod(0o600)
        cleaned = run_python_program(stale_program, str(state))
        assert cleaned.returncode == 0, cleaned.stderr
        assert not stale.exists(), "a SIGKILL leftover must be removed next run"

        unknown = state / ".rollback-database.operator-note"
        unknown.write_bytes(b"preserve")
        unknown.chmod(0o600)
        rejected = run_python_program(stale_program, str(state))
        assert rejected.returncode != 0 and unknown.read_bytes() == b"preserve"
        unknown.unlink()

        outside = Path(raw).resolve() / "outside"
        outside.write_bytes(b"unchanged")
        outside.chmod(0o600)
        stale.symlink_to(outside)
        rejected = run_python_program(stale_program, str(state))
        assert rejected.returncode != 0
        assert outside.read_bytes() == b"unchanged"
        stale.unlink()
        os.link(outside, stale)
        rejected = run_python_program(stale_program, str(state))
        assert rejected.returncode != 0 and outside.stat().st_nlink == 2


def test_stale_claim_cleanup(receiver_text: str) -> None:
    persist_program = localize_root_contract(
        heredoc_after(receiver_text, "persist_new_claim() {")
    )
    program = localize_root_contract(
        heredoc_after(receiver_text, "clean_stale_claims() {")
    )
    with tempfile.TemporaryDirectory(prefix="sync-stale-claim-test-") as raw:
        root = Path(raw).resolve() / "incoming"
        root.mkdir(mode=0o700)
        localized_persist = persist_program.replace(
            'Path("/var/lib/shuzijun-sync/incoming")', f"Path({str(root)!r})"
        )
        new_claim = root / "batch.A1b2C3"
        new_claim.mkdir(mode=0o700)
        persisted = run_python_program(localized_persist, str(root), str(new_claim))
        assert persisted.returncode == 0, persisted.stderr
        assert localized_persist.index("os.fsync(claim_descriptor)") < (
            localized_persist.index("os.fsync(root_descriptor)")
        )
        killed_after_inode_fsync = localized_persist.replace(
            "import os\n", "import os\nimport signal\n", 1
        ).replace(
            "    os.fsync(claim_descriptor)\n    os.fsync(root_descriptor)",
            "    os.fsync(claim_descriptor)\n"
            "    os.kill(os.getpid(), signal.SIGKILL)\n"
            "    os.fsync(root_descriptor)",
            1,
        )
        interrupted = run_python_program(
            killed_after_inode_fsync, str(root), str(new_claim)
        )
        assert interrupted.returncode == -signal.SIGKILL
        cleaned_prefix = run_python_program(program, str(root))
        assert cleaned_prefix.returncode == 0, cleaned_prefix.stderr
        assert not new_claim.exists(), "next run must recover a claim fsync crash prefix"

        claim = root / "batch.Abc123"
        nested = claim / "wp-content" / "uploads"
        nested.mkdir(mode=0o700, parents=True)
        for directory in (claim, claim / "wp-content", nested):
            directory.chmod(0o700)
        payload = nested / "image.jpg"
        payload.write_bytes(b"partial")
        payload.chmod(0o600)
        cleaned = run_python_program(program, str(root))
        assert cleaned.returncode == 0, cleaned.stderr
        assert not claim.exists()

        unknown = root / "operator-note"
        unknown.write_bytes(b"preserve")
        rejected = run_python_program(program, str(root))
        assert rejected.returncode != 0 and unknown.read_bytes() == b"preserve"
        unknown.unlink()

        external = Path(raw).resolve() / "external"
        external.mkdir()
        (external / "data").write_bytes(b"unchanged")
        (root / "batch.Linked").symlink_to(external, target_is_directory=True)
        rejected = run_python_program(program, str(root))
        assert rejected.returncode != 0
        assert (external / "data").read_bytes() == b"unchanged"

def test_live_hardlink_rejection(verifier_text: str) -> None:
    start = verifier_text.index("reject_checker_find_match() {")
    end = verifier_text.index("\n}\n", start) + 3
    function = verifier_text[start:end]
    with tempfile.TemporaryDirectory(prefix="sync-hardlink-source-test-") as raw:
        temp = Path(raw).resolve()
        root = temp / "site"
        uploads = root / "wp-content" / "uploads"
        uploads.mkdir(parents=True)
        original = uploads / "image.jpg"
        original.write_bytes(b"image")
        os.link(original, temp / "outside-site.jpg")
        command = (
            "set -euo pipefail\n"
            + function
            + "\nreject_checker_find_match 'hard-linked regular file remains in document root' "
            + '"$1" -xdev -type f -links +1\n'
        )
        result = subprocess.run(
            ["/bin/bash", "-c", command, "hardlink-test", str(root)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        assert result.returncode != 0
        assert "hard-linked regular file remains in document root" in result.stderr


def test_generation_initializer(readme_text: str) -> None:
    program = localize_root_contract(
        heredoc_after(readme_text, "initialize_generation_state() {")
    )
    allowed_start = program.index("allowed = {")
    allowed_end = program.index("}\n", allowed_start) + 2
    program = program[:allowed_start] + "allowed = {state_path}\n" + program[allowed_end:]
    with tempfile.TemporaryDirectory(prefix="sync-generation-init-test-") as raw:
        parent = Path(raw).resolve() / "state"
        parent.mkdir(mode=0o700)
        state = parent / "highest-accepted-generation"

        created = run_python_program(program, str(state))
        assert created.returncode == 0, created.stderr
        assert state.read_bytes() == b"0\n" and stat_mode(state) == 0o600

        state.write_bytes(b"37\n")
        state.chmod(0o600)
        existing = run_python_program(program, str(state))
        assert existing.returncode == 0, existing.stderr
        assert state.read_bytes() == b"37\n", "existing generation must never reset"

        state.write_bytes(b"invalid\n")
        invalid = run_python_program(program, str(state))
        assert invalid.returncode != 0
        assert state.read_bytes() == b"invalid\n", "invalid state must fail without rewrite"

        state.unlink()
        target = parent / "target"
        target.write_bytes(b"91\n")
        target.chmod(0o600)
        state.symlink_to(target)
        linked = run_python_program(program, str(state))
        assert linked.returncode != 0
        assert target.read_bytes() == b"91\n"

        state.unlink()
        os.link(target, state)
        hardlinked = run_python_program(program, str(state))
        assert hardlinked.returncode != 0
        assert state.read_bytes() == b"91\n" and state.stat().st_nlink == 2


def line_number(lines: list[str], fragment: str, start: int = 0) -> int:
    for index in range(start, len(lines)):
        line = lines[index]
        if fragment in line:
            return index
    raise AssertionError(f"missing required operation: {fragment}")


def python_heredocs(text: str) -> list[str]:
    """Return every single-quoted PY heredoc body for syntax validation."""
    lines = text.splitlines()
    payloads: list[str] = []
    index = 0
    while index < len(lines):
        if "<<'PY'" not in lines[index]:
            index += 1
            continue
        start = index + 1
        while start < len(lines) and lines[start].lstrip().startswith("|"):
            start += 1
        end = start
        while end < len(lines) and lines[end] != "PY":
            end += 1
        assert end < len(lines), "unterminated Python heredoc"
        payloads.append("\n".join(lines[start:end]) + "\n")
        index = end + 1
    return payloads


def verify_nginx_snippet_contract(
    sensitive_deny_text: str,
    legacy_images_text: str,
    wp_content_php_rule: str,
) -> None:
    """Keep upload and Nginx snippet assertions independent of the fixed checker path."""
    verifier_text = VERIFIER.read_text(encoding="utf-8")
    assert wp_content_php_rule in sensitive_deny_text
    assert "location ~* ^/images/.*\\.php(?:$|/) {" in sensitive_deny_text
    assert "wp-content/uploads/hero-images/$1;" in legacy_images_text
    for executable_pattern in (
        "-iname '*.php*'",
        "-iname '*.phtml*'",
        "-iname '*.phar*'",
        "-iname '.htaccess'",
        "-iname '.user.ini'",
        "-iname '*.sh'",
        "-iname '*.py'",
    ):
        assert executable_pattern in verifier_text
    assert "executable or config payload remains in uploads" in verifier_text


def main() -> None:
    receiver_text = RECEIVER.read_text(encoding="utf-8")
    sender_text = SENDER.read_text(encoding="utf-8")
    verifier_text = VERIFIER.read_text(encoding="utf-8")
    sensitive_deny_text = SENSITIVE_DENY.read_text(encoding="utf-8")
    legacy_images_text = LEGACY_IMAGES.read_text(encoding="utf-8")
    nginx_routing_smoke_text = NGINX_ROUTING_SMOKE.read_text(encoding="utf-8")
    nginx_readme_text = NGINX_README.read_text(encoding="utf-8")
    gate_text = SSH_GATE.read_text(encoding="utf-8")
    sudoers_text = SUDOERS.read_text(encoding="utf-8")
    sshd_match_text = SSHD_MATCH.read_text(encoding="utf-8")
    known_hosts = SYNC_KNOWN_HOSTS.read_bytes()
    fpm_guard_service = FPM_GUARD_SERVICE.read_bytes()
    lines = receiver_text.splitlines()
    authority_verifier_sha256 = hashlib.sha256(AUTHORITY_VERIFIER.read_bytes()).hexdigest()

    assert lines[:2] == ["#!/bin/bash", "set -euo pipefail"]
    assert "PATH=/usr/sbin:/usr/bin:/sbin:/bin" in lines
    assert "unset CDPATH ENV BASH_ENV PYTHONPATH PYTHONHOME || true" in lines
    assert 'SITE=/var/www/html/shuzijun.com.cn' in lines
    assert 'CLAIM_ROOT=/var/lib/shuzijun-sync/incoming' in lines
    assert 'STATE_ROOT=/var/lib/shuzijun-sync/state' in lines
    assert 'LAST_ACCEPTED_GENERATION="$STATE_ROOT/highest-accepted-generation"' in lines
    assert 'SELF=/usr/local/sbin/apply-shuzijun-sync' in lines
    assert "STAGE=" not in receiver_text
    assert "/tmp/shuzijun-stage" not in receiver_text
    assert "    local claim=$1\n    local manifest=\"$claim/shuzijun-sync-manifest.json\"" in receiver_text
    assert 'local claim=$1 manifest="$claim/' not in receiver_text

    authority_lock_comment = line_number(
        lines, "# Hold the root-only operation lock shared by sync deployment"
    )
    authority_root_gate = line_number(
        lines, "validate_sync_state_roots", authority_lock_comment
    )
    authority_lock = line_number(
        lines, 'enter_site_operation_lock_context "$@"', authority_root_gate
    )
    standby_preflight = line_number(lines, "verify_authority_role standby", authority_lock)
    self_gate = line_number(lines, 'test "$0" = "$SELF"', standby_preflight)
    attest_exit = line_number(lines, '"$1" == --attest', self_gate)
    protocol_exit = line_number(lines, '"$1" == --protocol', attest_exit)
    ingest_mode = line_number(lines, '"$1" == --ingest', protocol_exit)
    supervision_trap = line_number(lines, "trap 'finish_receiver $?' EXIT", ingest_mode)
    pre_guard_validation = line_number(lines, "validate_fpm_guard_unit", supervision_trap)
    signer_preflight = line_number(lines, "validate_allowed_signers", pre_guard_validation)
    state_root_preflight = line_number(lines, "validate_sync_state_roots", signer_preflight)
    rollback_sql_cleanup = line_number(lines, "clean_stale_rollback_sql", state_root_preflight)
    preflight = line_number(lines, "verify_webroot_security >/dev/null", rollback_sql_cleanup)
    recovery_gate = line_number(lines, "run_receiver_recovery_and_baseline", preflight)
    stale_claim_cleanup = line_number(lines, "clean_stale_claims", recovery_gate)
    claim = line_number(
        lines, 'CLAIM=$(mktemp -d "$CLAIM_ROOT/batch.XXXXXX")', stale_claim_cleanup
    )
    durable_claim = line_number(lines, 'persist_new_claim "$CLAIM"', claim)
    bounded_control = line_number(lines, 'read_control_frame "$CLAIM"', durable_claim)
    signed_control = line_number(lines, 'verify_control_signature "$CLAIM"', bounded_control)
    signed_payload = line_number(lines, 'GENERATION=$(ingest_signed_payload "$CLAIM")', signed_control)
    bounded_database = line_number(lines, 'prepare_database_sql "$CLAIM"', signed_payload)
    pre_accept_guard_validation = line_number(lines, "validate_fpm_guard_unit", bounded_database)
    backup_gate = line_number(lines, 'DEST=$(prepare_backup_destination', pre_accept_guard_validation)
    media_prepare = line_number(lines, 'prepare_uploads_transaction "$GENERATION"', backup_gate)
    metadata_sync = line_number(lines, 'sync -f "$SYNC_ROOT"', media_prepare)
    prepared_identity = line_number(
        lines,
        'PREPARED_AFTER_SYNC=$(validate_prepared_uploads_transaction "$GENERATION")',
        metadata_sync,
    )
    mutation_guard = line_number(lines, "MUTATION_GUARD=1", prepared_identity)
    fpm_isolation = line_number(lines, "if ! isolate_failed_fpm", mutation_guard)
    backup = line_number(lines, "wp db export - --add-drop-table", fpm_isolation)
    backup_store = line_number(lines, 'store_backup_archive "$DEST"', backup)
    backup_publish = line_number(lines, 'DEST=$(publish_backup_destination', backup_store)
    backup_sync = line_number(lines, 'sync -f "$DEST"', backup)
    replay_gate = line_number(lines, 'accept_generation "$GENERATION"', backup_publish)
    accepted_phase = line_number(lines, 'set_uploads_transaction_phase "$GENERATION" accepted', replay_gate)
    database_importing = line_number(
        lines, 'set_uploads_transaction_phase "$GENERATION" database-importing', accepted_phase
    )
    database_import = line_number(lines, 'wp db import "$SQL"', database_importing)
    schema_update = line_number(lines, "wp core update-db", database_import)
    cache_flush = line_number(lines, "wp cache flush --allow-root", schema_update)
    database_imported = line_number(
        lines, 'set_uploads_transaction_phase "$GENERATION" database-imported', cache_flush
    )
    atomic_exchange = line_number(lines, 'exchange_uploads_transaction "$GENERATION"', database_imported)
    standby_restart_gate = line_number(lines, "verify_authority_role standby", atomic_exchange)
    nginx_check = line_number(lines, "nginx -t -q", standby_restart_gate)
    runtime_guard_arm = line_number(lines, "arm_fpm_activation_guard", nginx_check)
    service_unmask = line_number(lines, "durably_unmask_fpm", runtime_guard_arm)
    service_start = line_number(lines, 'systemctl start "$FPM_SERVICE"', service_unmask)
    post_fpm_ready = line_number(lines, "verify_fpm_ready", service_start)
    post_smoke = line_number(lines, "if ! probe_standby_runtime", post_fpm_ready)
    active_publication = line_number(
        lines, 'publish_active_uploads_generation "$GENERATION"', post_smoke
    )
    commit_ready = line_number(
        lines, 'set_uploads_transaction_phase "$GENERATION" commit-ready', active_publication
    )
    runtime_guard_commit = line_number(lines, "commit_fpm_activation_guard", commit_ready)
    transaction_commit = line_number(
        lines, 'set_uploads_transaction_phase "$GENERATION" committed', runtime_guard_commit
    )
    transaction_finalize = line_number(
        lines, 'finalize_uploads_transaction "$GENERATION"', transaction_commit
    )
    success_flag = line_number(lines, "APPLY_SUCCEEDED=1", transaction_finalize)
    backup_retention = line_number(lines, 'retire_backup_history "$DEST"', success_flag)

    assert authority_root_gate < authority_lock < standby_preflight < self_gate < attest_exit
    assert attest_exit < protocol_exit < ingest_mode < supervision_trap
    assert supervision_trap < pre_guard_validation < signer_preflight
    assert signer_preflight < state_root_preflight < rollback_sql_cleanup < preflight
    assert preflight < recovery_gate < stale_claim_cleanup < claim
    assert claim < durable_claim < bounded_control < signed_control
    assert signed_control < signed_payload < bounded_database < pre_accept_guard_validation
    assert pre_accept_guard_validation < backup_gate < media_prepare
    assert media_prepare < metadata_sync < prepared_identity < mutation_guard
    assert mutation_guard < fpm_isolation < backup < backup_store < backup_sync < backup_publish
    assert backup_publish < replay_gate < accepted_phase < database_importing
    assert database_import < schema_update < cache_flush
    assert cache_flush < database_imported < atomic_exchange < standby_restart_gate
    assert standby_restart_gate < nginx_check < runtime_guard_arm
    assert runtime_guard_arm < service_unmask < service_start < post_fpm_ready < post_smoke
    assert post_smoke < active_publication < commit_ready < runtime_guard_commit
    assert runtime_guard_commit < transaction_commit
    assert transaction_commit < transaction_finalize < success_flag < backup_retention
    assert "--allow-root" in lines[cache_flush]
    assert any("cache=flushed" in line for line in lines)
    assert receiver_text.count("verify_webroot_security >/dev/null") >= 2
    sender_lines = sender_text.splitlines()
    sender_lock_comment = line_number(
        sender_lines, "# Prevent the sender from reading a release unit"
    )
    sender_root_gate = line_number(
        sender_lines, "validate_generation_state_root", sender_lock_comment
    )
    sender_lock = line_number(
        sender_lines, 'enter_site_operation_lock_context "$@"', sender_root_gate
    )
    sender_role = line_number(sender_lines, "verify_authority_role authority", sender_lock)
    sender_static_verify = line_number(sender_lines, '"$VERIFY" "$SITE"', sender_role)
    receiver_hash_gate = line_number(sender_lines, "receiver_attestation=", sender_static_verify)
    receiver_protocol_gate = line_number(sender_lines, "receiver_protocol=", receiver_hash_gate)
    sender_trap = line_number(sender_lines, "trap cleanup_sender EXIT", receiver_protocol_gate)
    sender_stale_cleanup = line_number(
        sender_lines, "manage_sender_staging clean-stale", sender_trap
    )
    sender_allocation = line_number(
        sender_lines, 'manage_sender_staging allocate "$TMP" "$TMP_TOKEN"', sender_stale_cleanup
    )
    sender_database_size = line_number(
        sender_lines, "DATABASE_LOGICAL_BYTES=$(read_database_logical_bytes)", sender_allocation
    )
    sender_preflight = line_number(
        sender_lines, 'audit_or_stage_uploads preflight "$TMP"', sender_database_size
    )
    sender_media_stage = line_number(
        sender_lines, 'audit_or_stage_uploads stage "$TMP"', sender_preflight
    )
    sender_freeze_marker = line_number(
        sender_lines, "FPM_FREEZE_TOKEN=$(primary_fpm_freeze_state create", sender_media_stage
    )
    sender_watchdog = line_number(
        sender_lines, "/usr/bin/systemd-run --quiet --collect", sender_freeze_marker
    )
    sender_freeze = line_number(
        sender_lines, '/usr/bin/systemctl stop "$FPM_SERVICE"', sender_watchdog
    )
    sender_frozen_snapshot = line_number(
        sender_lines, r'audit_or_stage_uploads snapshot \"\$2\" \"\$3\"', sender_freeze
    )
    sender_export = line_number(
        sender_lines, "wp db export - --add-drop-table", sender_frozen_snapshot
    )
    sender_database_bound = line_number(sender_lines, "| bound_database_sql_stream", sender_export)
    sender_database_store = line_number(
        sender_lines, r'| store_staged_database \"\$2\" \"\$3\"', sender_database_bound
    )
    sender_restore = line_number(
        sender_lines,
        'primary_fpm_freeze_state recover "$FPM_FREEZE_TOKEN"',
        sender_database_store,
    )
    second_receiver_hash_gate = line_number(
        sender_lines, "receiver_attestation=", sender_restore
    )
    second_receiver_protocol_gate = line_number(
        sender_lines, "receiver_protocol=", second_receiver_hash_gate
    )
    generation_issue = line_number(
        sender_lines, "GENERATION=$(issue_generation)", second_receiver_protocol_gate
    )
    sender_sign = line_number(sender_lines, "ssh-keygen -Y sign", generation_issue)
    receiver_apply = line_number(sender_lines, '"sudo $REMOTE_RECEIVER --ingest"', sender_sign)
    assert sender_root_gate < sender_lock < sender_role < sender_static_verify
    assert sender_static_verify < receiver_hash_gate
    assert sender_text.count('"$VERIFY" "$SITE"') == 1
    assert receiver_hash_gate < receiver_protocol_gate < sender_trap
    assert sender_trap < sender_stale_cleanup < sender_allocation
    assert sender_allocation < sender_database_size < sender_preflight
    assert sender_preflight < sender_media_stage < sender_freeze_marker < sender_watchdog
    assert sender_watchdog < sender_freeze < sender_frozen_snapshot
    assert sender_frozen_snapshot < sender_export < sender_database_bound < sender_database_store
    assert sender_database_store < sender_restore < second_receiver_hash_gate
    assert second_receiver_hash_gate < second_receiver_protocol_gate < generation_issue
    assert generation_issue < sender_sign < receiver_apply
    assert sender_text.count("receiver_attestation=") == 2
    assert sender_text.count("receiver_protocol=") == 2
    receiver_sha256 = hashlib.sha256(RECEIVER.read_bytes()).hexdigest()
    assert f"REMOTE_RECEIVER_SHA256={receiver_sha256}" in sender_text
    receiver_protocol = next(
        line.removeprefix("SYNC_PROTOCOL=")
        for line in receiver_text.splitlines()
        if line.startswith("SYNC_PROTOCOL=")
    )
    sender_protocol = next(
        line.removeprefix("SYNC_PROTOCOL=")
        for line in sender_text.splitlines()
        if line.startswith("SYNC_PROTOCOL=")
    )
    assert receiver_protocol == sender_protocol == "shuzijun-sync-receiver-v4-transactional-uploads"
    assert 'test "$receiver_protocol" = "$SYNC_PROTOCOL"' in sender_text
    assert known_hosts == (
        b"129.226.202.207 ssh-ed25519 "
        b"AAAAC3NzaC1lZDI1NTE5AAAAIH/BHsxAKRunOi8GK2tlH20Th7mj9zyTxKUq1lLa5kw0\n"
    )
    known_hosts_sha256 = hashlib.sha256(known_hosts).hexdigest()
    assert f"SYNC_KNOWN_HOSTS_SHA256={known_hosts_sha256}" in sender_text
    for ssh_pin in (
        "-F /dev/null",
        '-o UserKnownHostsFile="$SYNC_KNOWN_HOSTS"',
        "-o GlobalKnownHostsFile=/dev/null",
        "-o HostKeyAlgorithms=ssh-ed25519",
        "-o StrictHostKeyChecking=yes",
    ):
        assert ssh_pin in sender_text
    for sync_text in (receiver_text, sender_text):
        assert f"AUTHORITY_VERIFY_SHA256={authority_verifier_sha256}" in sync_text
        assert 'sha256sum "$verifier_fd_path"' in sync_text
        assert '"$AUTHORITY_VERIFY_SHA256"' in sync_text
        assert "for authority_verify_parent in /usr /usr/local /usr/local/sbin" in sync_text
        assert "authority_verify_parent_mode" in sync_text
        assert "/usr/bin/python3 -I \"$verifier_fd_path\"" in sync_text
        assert (
            '/usr/bin/python3 -I "$verifier_fd_path" "$expected_role" >/dev/null'
            in sync_text
        ), "role verifier output must not contaminate protocol or attestation stdout"
    assert 'gunzip -c "$DATABASE" > "$SQL"' not in receiver_text
    assert "MAX_DATABASE_SQL_BYTES = 4 * 1024 * 1024 * 1024" in receiver_text
    assert "zlib.decompressobj(16 + zlib.MAX_WBITS)" in receiver_text
    assert "decoder.unused_data" in receiver_text
    assert "os.link(temp_path, destination, follow_symlinks=False)" not in receiver_text
    assert "renameat2(-100, os.fsencode(temp_path), -100, os.fsencode(destination), 1)" in receiver_text
    assert "RETENTION_COUNT = 7" in receiver_text
    assert "shutil.rmtree.avoids_symlink_attacks" in receiver_text
    assert 'r"\\.shuzijun-sync-v1-[0-9]{8}-[0-9]{6}\\.retiring"' in receiver_text
    retention_rename = receiver_text.index("os.rename(expired, tombstone)")
    retention_remove = receiver_text.index("shutil.rmtree(tombstone)", retention_rename)
    assert retention_rename < retention_remove
    assert "MAX_BACKUP_ARCHIVE_BYTES = 8 * 1024 * 1024 * 1024" in receiver_text
    assert "ubuntu@" not in sender_text
    assert "shuzijun-sync-transport" in sender_text
    assert "/tmp/shuzijun-stage" not in sender_text
    assert "rsync -e" not in sender_text
    assert "rsync " not in sender_text
    assert "RSYNC_FILTERS" not in sender_text
    assert 'wp db export "$TMP/shuzijun-sync.sql"' not in sender_text
    assert 'wp db export - --add-drop-table --allow-root --quiet' in sender_text
    assert "--foreground" not in sender_text
    assert "/usr/bin/timeout --signal=TERM --kill-after=5s 20s" in sender_text
    assert "/usr/bin/timeout --signal=TERM --kill-after=10s 90s" in sender_text
    assert "FPM_FREEZE_ARM_LIMIT_SECONDS=120" in sender_text
    assert "FPM_FREEZE_LIMIT_SECONDS=180" in sender_text
    assert "/usr/bin/systemd-run --quiet --collect" in sender_text
    assert "--property=RuntimeMaxSec=7min" in sender_text
    assert 'primary_fpm_freeze_state begin-frozen "$FPM_FREEZE_TOKEN"' in sender_text
    assert "primary-fpm-freeze.main-recovery.json" in sender_text
    assert "primary-fpm-freeze.watchdog-recovery.json" in sender_text
    assert 'os.rename(other.name, claim.name' in sender_text
    assert 'primary_fpm_freeze_state recover "$FPM_FREEZE_TOKEN"' in sender_text
    assert "MIN_FREE_RESERVE = 1024 * 1024 * 1024" in sender_text
    assert "MAX_DIRECTORIES = 100_000" in sender_text
    assert 'os.stat(name, dir_fd=directory_fd, follow_symlinks=False)' in sender_text
    assert 'getattr(os, "O_NONBLOCK", 0)' in sender_text
    assert "identity(final) != identity(initial)" in sender_text
    assert "unset CDPATH ENV BASH_ENV PYTHONPATH PYTHONHOME TMPDIR" in sender_text
    assert "/tmp/shuzijun-sync." not in sender_text
    assert 'SENDER_STAGING_ROOT="$GENERATION_ROOT/sender-staging"' in sender_text
    assert 'r"batch\\.([0-9a-f]{32})"' in sender_text
    assert 'r"\\.retiring\\.([0-9a-f]{32})"' in sender_text
    assert "os.rename(path, retiring)" in sender_text
    assert '"sudo $REMOTE_RECEIVER --ingest"' in sender_text
    assert "ssh-keygen -Y verify" in receiver_text
    assert "SYNC_ALLOWED_SIGNERS=/etc/shuzijun/sync-signers" in receiver_text
    for signer_guard in (
        "test \"$(stat -c '%u:%g:%a' \"$parent\")\" = '0:0:755'",
        "test \"$(stat -c '%u:%g:%h:%a' \"$SYNC_ALLOWED_SIGNERS\")\" = '0:0:1:644'",
        "-I shuzijun-sync",
        "-n shuzijun-sync",
    ):
        assert signer_guard in receiver_text
    assert 'for state_directory in "$SYNC_ROOT" "$CLAIM_ROOT" "$STATE_ROOT"' in receiver_text
    assert 'test "$(stat -c \'%u:%g:%a\' "$state_directory")" = \'0:0:700\'' in receiver_text
    assert "for parent in /var /var/lib" in receiver_text
    assert "for parent in /var /var/lib" in sender_text
    assert "shuzijun-sync-manifest.json" in receiver_text
    for manifest_guard in (
        'set(document) != {"files", "generation", "version"}',
        'document["version"] != 2',
        "canonical != raw",
        "MAX_FILES = 100_000",
        "MAX_FILE_BYTES = 8 * 1024 * 1024 * 1024",
        "MAX_BATCH_BYTES = 64 * 1024 * 1024 * 1024",
        "MIN_FREE_RESERVE = 1024 * 1024 * 1024",
        'relative == "shuzijun-sync.sql.gz"',
        'relative.startswith("wp-content/uploads/")',
        '".php" in name',
        "metadata.st_nlink != 1",
        "if os.read(0, 1)",
    ):
        assert manifest_guard in receiver_text
    for replay_guard in (
        "candidate <= current",
        'f".highest-accepted.{secrets.token_hex(16)}"',
        "os.replace(temp_path, state_path)",
        "os.fsync(directory)",
    ):
        assert replay_guard in receiver_text
    for sender_generation_guard in (
        'GENERATION_ROOT=/var/lib/shuzijun-sync',
        'GENERATION_STATE="$GENERATION_ROOT/highest-issued-generation"',
        'f".highest-issued.{secrets.token_hex(16)}"',
        "clean_stale_generation_temporaries",
        're.compile(r"\\.highest-issued\\.([0-9a-f]{32})")',
        "os.replace(temp_path, state_path)",
        'document = {"files": files, "generation": generation, "version": 2}',
    ):
        assert sender_generation_guard in sender_text
    assert 'receive("shuzijun-sync-manifest.json", 32 * 1024 * 1024)' in receiver_text
    assert 'receive("shuzijun-sync-manifest.json.sig", 64 * 1024)' in receiver_text
    assert 'verify_control_signature "$CLAIM"' in receiver_text
    assert receiver_text.index('verify_control_signature "$CLAIM"') < receiver_text.index(
        'GENERATION=$(ingest_signed_payload "$CLAIM")'
    )
    assert "ssh-keygen -Y sign -q" in sender_text
    assert "-n shuzijun-sync" in sender_text
    assert receiver_text.count("rest_route=%2Fshuzijun%2Fv1%2Fapp-content") == 2
    assert "yishu_account_authority_unavailable" in receiver_text
    for isolation_guard in (
        'systemctl mask --now "$FPM_SERVICE"',
        'systemctl stop "$FPM_SERVICE"',
        "LoadState --value",
        "ActiveState --value",
        "SubState --value",
        '"$enabled_state" == masked',
        'read_unit_file_state "$FPM_SERVICE"',
    ):
        assert isolation_guard in receiver_text
    isolate_start = receiver_text.index("isolate_failed_fpm()")
    isolate_body = receiver_text[isolate_start : receiver_text.index("\n}\n", isolate_start) + 3]
    assert "|| true" not in isolate_body
    assert "sync -f /etc/systemd/system" in isolate_body
    assert receiver_text.count('systemctl unmask "$FPM_SERVICE"') == 1
    assert receiver_text.count("durably_unmask_fpm") == 4  # definition + three callers
    finish_body = shell_function(receiver_text, "finish_receiver")
    assert "isolate_failed_fpm" in finish_body
    assert "systemctl unmask" not in finish_body
    for ready_guard in (
        '"$load_state" == loaded',
        '"$active_state" == active',
        '"$sub_state" == running',
        '"$enabled_state" == enabled',
        '-z "$triggered_by"',
    ):
        assert ready_guard in receiver_text
    guard_branch = receiver_text.index('if [[ $# -eq 4 && "$1" == --guard-watch ]]')
    finalizer_branch = receiver_text.index(
        'if [[ $# -eq 2 && "$1" == --guard-finalize ]]'
    )
    site_lock = receiver_text.index('enter_site_operation_lock_context "$@"')
    assert guard_branch < finalizer_branch < site_lock
    finalizer_start = receiver_text.index("finalize_fpm_activation_guard() {")
    finalizer_end = receiver_text.index("\n}\n", finalizer_start)
    finalizer_body = receiver_text[finalizer_start:finalizer_end]
    assert '"$EUID" -eq 0' in finalizer_body
    assert '"$committed" == "$FPM_GUARD_COMMIT"' in finalizer_body
    assert "validate_fpm_guard_runtime_context" in finalizer_body
    assert "validate_fpm_guard_commit_matches_accepted" in finalizer_body
    assert "flock -n 6" in finalizer_body
    assert "isolate_fpm_from_activation_guard" in finalizer_body
    runtime_context_start = receiver_text.index("validate_fpm_guard_runtime_context() {")
    runtime_context_end = receiver_text.index("\n}\n", runtime_context_start)
    runtime_context_body = receiver_text[runtime_context_start:runtime_context_end]
    assert "validate_sync_state_roots" in runtime_context_body
    assert 'test "$0" = "$SELF"' in runtime_context_body
    assert receiver_text.index('test -x "$VERIFY"') > finalizer_branch
    arm_start = receiver_text.index("arm_fpm_activation_guard() {")
    arm_end = receiver_text.index("\n}\n", arm_start)
    arm_body = receiver_text[arm_start:arm_end]
    arm_enable = arm_body.index('systemctl enable "$FPM_GUARD_UNIT"')
    arm_validate = arm_body.index("validate_fpm_guard_unit", arm_enable)
    arm_fsync = arm_body.index("sync -f /etc/systemd/system", arm_validate)
    arm_start_unit = arm_body.index('systemctl start "$FPM_GUARD_UNIT"', arm_fsync)
    assert arm_enable < arm_validate < arm_fsync < arm_start_unit
    fpm_guard_sha256 = hashlib.sha256(fpm_guard_service).hexdigest()
    assert f"FPM_GUARD_UNIT_SHA256={fpm_guard_sha256}" in receiver_text
    assert (
        b"ExecStart=/usr/local/sbin/apply-shuzijun-sync --guard-watch "
        b"/var/lib/shuzijun-sync/state/fpm-activation-guard.lease "
        b"/var/lib/shuzijun-sync/state/fpm-activation-guard-v4.armed "
        b"/var/lib/shuzijun-sync/state/fpm-activation-guard-v4.committed\n"
        in fpm_guard_service
    )
    assert b"Type=notify\n" in fpm_guard_service
    assert b"NotifyAccess=all\n" in fpm_guard_service
    assert b"RemainAfterExit=no\n" in fpm_guard_service
    assert (
        b"ExecStopPost=/usr/local/sbin/apply-shuzijun-sync --guard-finalize "
        b"/var/lib/shuzijun-sync/state/fpm-activation-guard-v4.committed\n"
        in fpm_guard_service
    )
    assert b"Restart=on-failure\n" in fpm_guard_service
    assert b"RestartPreventExitStatus=77\n" in fpm_guard_service
    assert b"SuccessExitStatus=" not in fpm_guard_service
    assert b"RuntimeMaxSec=2min\n" in fpm_guard_service
    assert b"StartLimitIntervalSec=10min\n" in fpm_guard_service
    assert b"StartLimitBurst=3\n" in fpm_guard_service
    assert b"ReadWritePaths=/var/lib/shuzijun-sync/state\n" in fpm_guard_service
    assert (
        b"ReadOnlyPaths=/var/www/html/shuzijun.com.cn/wp-content/uploads\n"
        in fpm_guard_service
    )
    assert b"InaccessiblePaths=-/root -/var/backups\n" in fpm_guard_service
    assert b"Before=php8.3-fpm.service\n" in fpm_guard_service
    assert b"RequiredBy=php8.3-fpm.service\n" in fpm_guard_service
    assert "FPM_SERVICE=php8.3-fpm.service" in receiver_text
    for runtime_guard_property in (
        "--property=Type --value",
        "--property=NotifyAccess --value",
        "--property=RemainAfterExit --value",
        "--property=RuntimeMaxUSec --value",
        "--property=Restart --value",
        "--property=RestartUSec --value",
        "--property=StartLimitIntervalUSec --value",
        "--property=StartLimitBurst --value",
        "--property=Before --value",
        "--property=RequiredBy --value",
    ):
        assert runtime_guard_property in receiver_text
    assert 'chown www-data:www-data "$wp_content"' not in receiver_text
    assert "renameat2" in receiver_text
    assert "RENAME_EXCHANGE = 2" in receiver_text
    assert 'exchange_uploads_transaction "$GENERATION"' in receiver_text
    assert 'publish_active_uploads_generation "$GENERATION"' in receiver_text
    prepared_validation_start = receiver_text.index('elif action == "validate-prepared":')
    prepared_validation_end = receiver_text.index(
        'elif action == "publish-active":', prepared_validation_start
    )
    prepared_validation = receiver_text[
        prepared_validation_start:prepared_validation_end
    ]
    assert "validate_tree" not in prepared_validation
    assert "hash_file" not in prepared_validation
    assert "strict_directory(live" in prepared_validation
    assert "strict_directory(candidate" in prepared_validation
    remove_claim_body = shell_function(receiver_text, "remove_claim_tree")
    assert '/usr/bin/rm -rf --one-file-system -- "$claim" || return 1' in (
        remove_claim_body
    )
    assert 'sync -f "$CLAIM_ROOT" || return 1' in remove_claim_body
    assert '"commit-ready", "committed"' in receiver_text
    assert 'manage_uploads_transaction validate-commit "$accepted"' not in receiver_text
    assert 'active_transaction["phase"] not in {"commit-ready", "committed"}' in receiver_text
    assert 'set_uploads_transaction_phase "$GENERATION" commit-ready' in receiver_text
    assert "os.rename(candidate, live)" not in receiver_text
    assert "os.replace(candidate, live)" not in receiver_text
    assert "rsync -a --delete --no-owner" not in receiver_text
    assert '"${RSYNC_FILTERS[@]}"' not in receiver_text
    assert '"$CLAIM/wp-content/" "$SITE/wp-content/"' not in receiver_text
    assert "stat -c '%a %U:%G' \"$wp_content\"" in verifier_text
    assert "'755 root:www-data'" in verifier_text
    assert '-path "$wp_content/uploads"' in verifier_text
    assert '-path "$wp_content/cache"' in verifier_text
    assert "-type l -print -quit" in verifier_text
    assert "-iname '*.php' ! -name '*.php'" in verifier_text
    assert 'uploads_root="$site_root/wp-content/uploads"' in verifier_text
    assert "-iname '*.php*'" in verifier_text
    assert "executable or config payload remains in uploads" in verifier_text
    assert gate_text.startswith("#!/bin/sh\nset -eu\n")
    assert gate_text.count("exec /usr/bin/sudo -n /usr/local/sbin/apply-shuzijun-sync") == 3
    assert "SSH_ORIGINAL_COMMAND" in gate_text
    assert "command denied" in gate_text
    assert os.stat(SSH_GATE).st_mode & 0o777 == 0o755
    assert sudoers_text == (
        "shuzijun-sync-transport ALL=(root:root) NOPASSWD: "
        "/usr/local/sbin/apply-shuzijun-sync --attest, "
        "/usr/local/sbin/apply-shuzijun-sync --protocol, "
        "/usr/local/sbin/apply-shuzijun-sync --ingest\n"
    )
    assert "Cmnd_Alias" not in sudoers_text
    assert "NOPASSWD: ALL" not in sudoers_text
    assert sshd_match_text.startswith("Match User shuzijun-sync-transport\n")
    assert "    AuthenticationMethods publickey\n" in sshd_match_text
    assert "    ForceCommand /usr/local/sbin/shuzijun-sync-ssh-gate\n" in sshd_match_text
    assert sshd_match_text.endswith("\nMatch all\n")
    for script_text in (receiver_text, sender_text):
        payloads = python_heredocs(script_text)
        assert payloads
        for payload in payloads:
            ast.parse(payload)
    assert "shuzijun-legacy-images-alias.conf" in verifier_text
    wp_content_php_rule = "location ~* ^/wp-content/.*\\.php(?:$|/) {"
    assert wp_content_php_rule in sensitive_deny_text
    assert wp_content_php_rule in verifier_text
    assert "wp-content/(?:uploads|cache)" not in sensitive_deny_text
    assert "^/images/.*\\.php" in sensitive_deny_text
    assert legacy_images_text.count("location ~* ^/images/") == 2
    assert "wp-content/uploads/hero-images/$1" in legacy_images_text
    assert "location /images/" not in legacy_images_text
    assert "location ^~ /images/" not in legacy_images_text
    for required_probe in (
        "/wp-content/mu-plugins/shuzijun-app-content.php",
        "/wp-content/mu-plugins/shuzijun-app-content.PHP",
        "/wp-content/mu-plugins/shuzijun-app-content.php/path-info",
        "/wp-content/mu-plugins/shuzijun-app-content%2ephp",
        "/wp-json/shuzijun/v1/app-content",
        "/index.php?rest_route=%2Fshuzijun%2Fv1%2Fapp-content",
        "/?rest_route=%2Fshuzijun%2Fv1%2Fapp-content",
    ):
        assert required_probe in nginx_routing_smoke_text
    assert nginx_routing_smoke_text.count('assert_status 404 "/wp-content/') >= 4
    assert nginx_routing_smoke_text.count("assert_secure_api_error") >= 4
    assert "fan_session_required" in nginx_routing_smoke_text
    assert "yishu_account_authority_unavailable" in nginx_routing_smoke_text
    assert 'origin_role=${2:-www}' in nginx_routing_smoke_text
    assert 'node_role=${3:-}' in nginx_routing_smoke_text
    assert '"$origin_role" == www' in nginx_routing_smoke_text
    assert "https://img.shuzijun.com.cn img standby" in nginx_readme_text
    assert "https://www.shuzijun.com.cn www authority" in nginx_readme_text
    assert "https://www.shuzijun.com.cn www standby" in nginx_readme_text
    verify_nginx_snippet_contract(
        sensitive_deny_text,
        legacy_images_text,
        wp_content_php_rule,
    )
    assert "-links +1" in verifier_text
    assert "hard-linked regular file remains in document root" in verifier_text
    test_live_hardlink_rejection(verifier_text)
    test_bounded_database_decompression(receiver_text)
    test_backup_retention(receiver_text)
    test_sender_database_streams(sender_text)
    test_sender_database_logical_query_deadline(sender_text)
    test_receiver_database_backup_bounds(receiver_text)
    test_secure_sync_logs(receiver_text, sender_text)
    test_ingest_receipt_exactness(sender_text)
    test_sender_upload_staging(sender_text)
    test_sender_staging_recovery(sender_text)
    test_primary_fpm_freeze_marker_linux(sender_text)
    test_uploads_transaction_linux(receiver_text)
    test_receiver_failure_guard(receiver_text)
    test_preactivation_metadata_durability(receiver_text)
    test_post_commit_supervision(receiver_text)
    test_durable_fpm_unmask(receiver_text)
    test_pending_stable_activation_resume(receiver_text)
    test_fpm_guard_state(receiver_text)
    test_state_temporary_recovery(receiver_text)
    test_sender_generation_state_recovery(sender_text)
    test_bootstrap_fpm_commit_recovery(receiver_text)
    test_fpm_guard_activation_is_constant_time(receiver_text)
    test_commit_ready_three_state(receiver_text)
    test_fpm_guard_runtime_decisions(receiver_text)
    test_fpm_guard_stop_finalizer(receiver_text)
    test_receiver_condition_context_failure_propagation(receiver_text)
    test_receiver_external_deadline_contract(receiver_text)
    test_rollback_sql_cleanup_on_cd_failure(receiver_text)
    test_stale_claim_cleanup(receiver_text)
    readme_text = Path("Server/operations/README.md").read_text(encoding="utf-8")
    assert "install -o root -g root -m 0600 /dev/null" not in readme_text
    assert "printf '0\\n' > /var/lib/shuzijun-sync" not in readme_text
    assert "os.link(temp_path, state_path, follow_symlinks=False)" in readme_text
    test_generation_initializer(readme_text)

    print("sync-script-contract-test: passed")


if __name__ == "__main__":
    main()
