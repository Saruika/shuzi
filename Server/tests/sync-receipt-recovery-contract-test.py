import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


SENDER = Path("Server/operations/sync-to-backup")
RECEIVER = Path("Server/operations/apply-shuzijun-sync")
PROTOCOL = "shuzijun-sync-receiver-v4-transactional-uploads"
EVIDENCE = "a" * 64
OLD_EVIDENCE = "b" * 64
INGEST_RECEIVER = "c" * 64
QUERY_RECEIVER = "d" * 64
RELEASE_ID = "e" * 64
OLD_RELEASE_ID = "f" * 64


def heredoc_after(text: str, marker: str) -> str:
    marker_offset = text.index(marker)
    opener = text.index("<<'PY'", marker_offset)
    start = text.index("\n", opener) + 1
    end = text.index("\nPY\n", start)
    return text[start:end] + "\n"


def shell_function(text: str, name: str) -> str:
    start = text.index(f"{name}() {{")
    end = text.index("\n}\n", start) + 3
    return text[start:end]


def localize_root_contract(program: str) -> str:
    return program.replace(".st_uid != 0", ".st_uid != os.getuid()").replace(
        ".st_gid != 0", ".st_gid != os.getgid()"
    )


def localize_linux_rename_noreplace(program: str) -> str:
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


def canonical_json(document: dict[str, object]) -> bytes:
    return (
        json.dumps(document, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
        + "\n"
    ).encode("ascii")


def pending_document(
    generation: int = 10, expected_release_id: str = ""
) -> dict[str, object]:
    return {
        "evidence_sha256": EVIDENCE,
        "expected_release_id": expected_release_id,
        "generation": generation,
        "ingest_receiver_sha256": INGEST_RECEIVER,
        "protocol": PROTOCOL,
        "version": 5,
    }


def resolution_document(
    generation: int,
    *,
    accepted: int | None = None,
    active: int | None = None,
    evidence: str = EVIDENCE,
    release_id: str = RELEASE_ID,
    outcome: str = "committed",
    reason: str = "queried-after-ambiguous-ack",
    runtime: str = "healthy",
) -> dict[str, object]:
    accepted = generation if accepted is None else accepted
    active = generation if active is None else active
    return {
        "accepted_generation": accepted,
        "active_evidence_sha256": evidence,
        "active_generation": active,
        "committed_generation": active,
        "generation": generation,
        "ingest_receiver_sha256": INGEST_RECEIVER,
        "outcome": outcome,
        "protocol": PROTOCOL,
        "query_receiver_sha256": QUERY_RECEIVER,
        "reason": reason,
        "release_id": release_id,
        "runtime": runtime,
        "version": 5,
    }


def reconcile_receipt(
    accepted: int,
    active: int,
    committed: int,
    *,
    evidence: str = EVIDENCE,
    release_id: str = RELEASE_ID,
    receiver: str = QUERY_RECEIVER,
    protocol: str = PROTOCOL,
    transaction: str = "none",
    runtime: str = "healthy",
) -> str:
    return (
        f"sync-reconcile-v5 accepted={accepted} active={active} "
        f"committed={committed} evidence-sha256={evidence} "
        f"release-id={release_id} receiver-sha256={receiver} "
        f"protocol={protocol} transaction={transaction} runtime={runtime}\n"
    )


class ReceiptFixture:
    def __init__(
        self, parent: Path, name: str, sender_text: str, *, generation: int = 10
    ) -> None:
        self.generation = generation
        self.root = (parent / name).resolve()
        self.root.mkdir(mode=0o700)
        self.root.chmod(0o700)
        self.issued = self.root / "highest-issued-generation"
        self.pending = self.root / "pending-receipt-v5.json"
        self.resolution = self.root / "last-resolution-v5.json"
        self.issued.write_bytes(f"{generation}\n".encode("ascii"))
        self.issued.chmod(0o600)

        program = localize_root_contract(
            heredoc_after(sender_text, "manage_receipt_state() {")
        )
        fixed_root = 'Path("/var/lib/shuzijun-sync")'
        assert program.count(fixed_root) == 1
        program = program.replace(fixed_root, f"Path({str(self.root)!r})")
        self.program = localize_linux_rename_noreplace(program)

    def invoke(
        self,
        action: str,
        *arguments: str,
        selected: str | None = None,
        environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        # Keep the fixtures readable while exercising the production
        # hex-encoded control-channel boundary.  Raw control records must not
        # travel through shell variables because command substitution strips
        # trailing newlines and cannot preserve arbitrary bytes.
        if action == "resolve-line":
            action = "resolve-hex"
            arguments = (arguments[0].encode("ascii").hex(), *arguments[1:])
        return subprocess.run(
            [
                sys.executable,
                "-I",
                "-c",
                selected or self.program,
                action,
                str(self.root),
                str(self.issued),
                str(self.pending),
                str(self.resolution),
                *arguments,
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            check=False,
        )

    def create(self, *, expected_release_id: str = "") -> bytes:
        result = self.invoke(
            "create",
            str(self.generation),
            EVIDENCE,
            expected_release_id,
            INGEST_RECEIVER,
            PROTOCOL,
        )
        assert result.returncode == 0, result.stderr
        assert result.stdout == ""
        return self.pending.read_bytes()


def assert_safe_regular(path: Path) -> None:
    metadata = path.stat()
    assert stat.S_ISREG(metadata.st_mode)
    assert stat.S_IMODE(metadata.st_mode) == 0o600
    assert metadata.st_uid == os.getuid() and metadata.st_gid == os.getgid()
    assert metadata.st_nlink == 1


def test_pending_state(sender_text: str) -> None:
    with tempfile.TemporaryDirectory(prefix="sync-receipt-pending-") as raw:
        parent = Path(raw).resolve()
        fixture = ReceiptFixture(parent, "normal", sender_text)
        expected = canonical_json(pending_document())
        assert fixture.create() == expected
        assert set(json.loads(expected)) == {
            "evidence_sha256",
            "expected_release_id",
            "generation",
            "ingest_receiver_sha256",
            "protocol",
            "version",
        }
        assert fixture.pending.read_bytes() == expected
        assert_safe_regular(fixture.pending)
        listed = fixture.invoke("pending")
        assert listed.returncode == 0, listed.stderr
        assert listed.stdout.encode("ascii") == expected

        identity = (fixture.pending.stat().st_dev, fixture.pending.stat().st_ino)
        assert fixture.create() == expected
        assert (fixture.pending.stat().st_dev, fixture.pending.stat().st_ino) == identity
        conflicting = fixture.invoke(
            "create", "10", OLD_EVIDENCE, "", INGEST_RECEIVER, PROTOCOL
        )
        assert conflicting.returncode != 0
        assert fixture.pending.read_bytes() == expected

        legacy = ReceiptFixture(parent, "legacy", sender_text)
        legacy_expected = canonical_json(pending_document(expected_release_id=RELEASE_ID))
        assert legacy.create(expected_release_id=RELEASE_ID) == legacy_expected

        invalid_create_arguments = (
            ("0", EVIDENCE, "", INGEST_RECEIVER, PROTOCOL),
            ("010", EVIDENCE, "", INGEST_RECEIVER, PROTOCOL),
            (str(2**63), EVIDENCE, "", INGEST_RECEIVER, PROTOCOL),
            ("10", EVIDENCE.upper(), "", INGEST_RECEIVER, PROTOCOL),
            ("10", EVIDENCE[:-1], "", INGEST_RECEIVER, PROTOCOL),
            ("10", EVIDENCE, "not-a-release", INGEST_RECEIVER, PROTOCOL),
            ("10", EVIDENCE, "", INGEST_RECEIVER.upper(), PROTOCOL),
            ("10", EVIDENCE, "", INGEST_RECEIVER, PROTOCOL + "-changed"),
        )
        for index, arguments in enumerate(invalid_create_arguments):
            rejected = ReceiptFixture(parent, f"invalid-create-{index}", sender_text)
            result = rejected.invoke("create", *arguments)
            assert result.returncode != 0, arguments
            assert not rejected.pending.exists()

        malformed_documents: list[bytes] = []
        document = pending_document()
        malformed_documents.append(canonical_json({**document, "extra": True}))
        missing = dict(document)
        missing.pop("expected_release_id")
        malformed_documents.append(canonical_json(missing))
        malformed_documents.append(canonical_json({**document, "generation": True}))
        malformed_documents.append(canonical_json({**document, "version": 5.0}))
        malformed_documents.append(json.dumps(document).encode("ascii") + b"\n")
        malformed_documents.append(canonical_json(document).rstrip(b"\n"))
        for index, payload in enumerate(malformed_documents):
            rejected = ReceiptFixture(parent, f"malformed-{index}", sender_text)
            rejected.pending.write_bytes(payload)
            rejected.pending.chmod(0o600)
            result = rejected.invoke("pending")
            assert result.returncode != 0, index
            assert rejected.pending.read_bytes() == payload

        wrong_mode = ReceiptFixture(parent, "wrong-mode", sender_text)
        wrong_mode.pending.write_bytes(expected)
        wrong_mode.pending.chmod(0o644)
        assert wrong_mode.invoke("pending").returncode != 0
        assert wrong_mode.pending.read_bytes() == expected

        symlinked = ReceiptFixture(parent, "symlink", sender_text)
        symlink_target = parent / "symlink-target"
        symlink_target.write_bytes(expected)
        symlink_target.chmod(0o600)
        symlinked.pending.symlink_to(symlink_target)
        assert symlinked.invoke("pending").returncode != 0
        assert symlinked.pending.is_symlink() and symlink_target.read_bytes() == expected

        hardlinked = ReceiptFixture(parent, "hardlink", sender_text)
        hardlink_target = parent / "hardlink-target"
        hardlink_target.write_bytes(expected)
        hardlink_target.chmod(0o600)
        os.link(hardlink_target, hardlinked.pending)
        assert hardlinked.invoke("pending").returncode != 0
        assert hardlink_target.stat().st_nlink == 2


def test_reconciliation_matrix(sender_text: str) -> None:
    with tempfile.TemporaryDirectory(prefix="sync-receipt-matrix-") as raw:
        parent = Path(raw).resolve()

        committed = ReceiptFixture(parent, "committed", sender_text)
        pending_bytes = committed.create()
        result = committed.invoke(
            "resolve-line",
            reconcile_receipt(10, 10, 10),
            "queried-after-ambiguous-ack",
            QUERY_RECEIVER,
        )
        assert result.returncode == 0, result.stderr
        assert result.stdout == "committed queried-after-ambiguous-ack 10\n"
        assert committed.pending.read_bytes() == pending_bytes
        assert committed.resolution.read_bytes() == canonical_json(
            resolution_document(10)
        )
        assert_safe_regular(committed.resolution)
        cleared = committed.invoke("clear", QUERY_RECEIVER)
        assert cleared.returncode == 0, cleared.stderr
        assert not committed.pending.exists() and committed.resolution.is_file()

        accepted_not_committed = (
            ("prior-healthy", 9, 9, 9, "healthy"),
            ("rolled-back-isolated", 10, 9, 9, "isolated"),
        )
        for name, accepted, active, durable, runtime in accepted_not_committed:
            fixture = ReceiptFixture(parent, name, sender_text)
            original = fixture.create()
            result = fixture.invoke(
                "resolve-line",
                reconcile_receipt(
                    accepted,
                    active,
                    durable,
                    evidence=OLD_EVIDENCE,
                    release_id=OLD_RELEASE_ID,
                    runtime=runtime,
                ),
                "startup-recovery",
                QUERY_RECEIVER,
            )
            assert result.returncode == 0, result.stderr
            assert result.stdout == "not-committed startup-recovery 10\n"
            assert fixture.pending.read_bytes() == original
            assert fixture.resolution.read_bytes() == canonical_json(
                resolution_document(
                    10,
                    accepted=accepted,
                    active=active,
                    evidence=OLD_EVIDENCE,
                    release_id=OLD_RELEASE_ID,
                    outcome="not-committed",
                    reason="startup-recovery",
                    runtime=runtime,
                )
            )
            assert fixture.invoke("clear", QUERY_RECEIVER).returncode == 0
            assert not fixture.pending.exists()

        semantic_rejections = (
            (
                "ambiguous-middle-accepted",
                reconcile_receipt(
                    9, 8, 8,
                    evidence=OLD_EVIDENCE,
                    release_id=OLD_RELEASE_ID,
                    runtime="isolated",
                ),
            ),
            (
                "rollback-reported-healthy",
                reconcile_receipt(
                    10, 9, 9,
                    evidence=OLD_EVIDENCE,
                    release_id=OLD_RELEASE_ID,
                    runtime="healthy",
                ),
            ),
            (
                "prior-reported-isolated",
                reconcile_receipt(
                    9, 9, 9,
                    evidence=OLD_EVIDENCE,
                    release_id=OLD_RELEASE_ID,
                    runtime="isolated",
                ),
            ),
            ("committed-not-active", reconcile_receipt(10, 10, 9)),
            ("active-exceeds-accepted", reconcile_receipt(9, 10, 10)),
            ("accepted-exceeds-pending", reconcile_receipt(11, 10, 10)),
            ("wrong-evidence", reconcile_receipt(10, 10, 10, evidence=OLD_EVIDENCE)),
            ("wrong-query-receiver", reconcile_receipt(10, 10, 10, receiver="0" * 64)),
            ("wrong-protocol", reconcile_receipt(10, 10, 10, protocol=PROTOCOL + "-v5")),
            ("open-transaction", reconcile_receipt(10, 10, 10, transaction="open")),
        )
        for name, receipt in semantic_rejections:
            fixture = ReceiptFixture(parent, name, sender_text)
            original = fixture.create()
            result = fixture.invoke(
                "resolve-line", receipt, "queried-after-ambiguous-ack", QUERY_RECEIVER
            )
            assert result.returncode != 0, name
            assert fixture.pending.read_bytes() == original
            assert not fixture.resolution.exists()

        exact = reconcile_receipt(10, 10, 10)
        grammar_rejections = (
            exact.rstrip("\n"),
            exact.replace("\n", "\n\n"),
            "prefix " + exact,
            exact.replace(" runtime=healthy\n", " extra=true runtime=healthy\n"),
            exact + "\x1e",
            exact.replace("accepted=10 active=10", "active=10 accepted=10"),
            exact.replace("accepted=10", "accepted=010", 1),
            exact.replace("transaction=none ", ""),
            exact.replace("evidence-sha256=" + EVIDENCE, "evidence-sha256=" + EVIDENCE.upper()),
            exact + "\x00",
        )
        for index, receipt in enumerate(grammar_rejections):
            fixture = ReceiptFixture(parent, f"grammar-{index}", sender_text)
            original = fixture.create()
            result = fixture.invoke(
                "resolve-line", receipt, "queried-after-ambiguous-ack", QUERY_RECEIVER
            )
            assert result.returncode != 0, repr(receipt)
            assert fixture.pending.read_bytes() == original
            assert not fixture.resolution.exists()

        for index, encoded in enumerate(
            (
                exact.encode("ascii").hex().upper(),
                exact.encode("ascii").hex() + "0",
                "not-hex",
            )
        ):
            fixture = ReceiptFixture(parent, f"invalid-hex-{index}", sender_text)
            original = fixture.create()
            result = fixture.invoke(
                "resolve-hex", encoded, "queried-after-ambiguous-ack", QUERY_RECEIVER
            )
            assert result.returncode != 0, encoded
            assert fixture.pending.read_bytes() == original
            assert not fixture.resolution.exists()

        legacy_ok = ReceiptFixture(parent, "legacy-ok", sender_text)
        legacy_ok.create(expected_release_id=RELEASE_ID)
        assert legacy_ok.invoke(
            "resolve-line",
            reconcile_receipt(10, 10, 10),
            "legacy-v4-stdout-contamination",
            QUERY_RECEIVER,
        ).returncode == 0

        legacy_rejections = (
            reconcile_receipt(10, 10, 10, release_id=OLD_RELEASE_ID),
            reconcile_receipt(
                9, 9, 9,
                evidence=OLD_EVIDENCE,
                release_id=OLD_RELEASE_ID,
                runtime="healthy",
            ),
            reconcile_receipt(
                10, 9, 9,
                evidence=OLD_EVIDENCE,
                release_id=OLD_RELEASE_ID,
                runtime="isolated",
            ),
        )
        for index, receipt in enumerate(legacy_rejections):
            fixture = ReceiptFixture(parent, f"legacy-rejected-{index}", sender_text)
            original = fixture.create(expected_release_id=RELEASE_ID)
            result = fixture.invoke(
                "resolve-line",
                receipt,
                "legacy-v4-stdout-contamination",
                QUERY_RECEIVER,
            )
            assert result.returncode != 0, index
            assert fixture.pending.read_bytes() == original
            assert not fixture.resolution.exists()


def test_clear_requires_exact_durable_resolution(sender_text: str) -> None:
    with tempfile.TemporaryDirectory(prefix="sync-receipt-clear-auth-") as raw:
        parent = Path(raw).resolve()

        def rejected(
            name: str,
            resolution: dict[str, object] | None,
            *,
            expected_release_id: str = "",
            clear_receiver: str = QUERY_RECEIVER,
        ) -> None:
            fixture = ReceiptFixture(parent, name, sender_text)
            pending = fixture.create(expected_release_id=expected_release_id)
            if resolution is not None:
                fixture.resolution.write_bytes(canonical_json(resolution))
                fixture.resolution.chmod(0o600)
            result = fixture.invoke("clear", clear_receiver)
            assert result.returncode != 0, name
            assert fixture.pending.read_bytes() == pending

        rejected("missing-resolution", None)
        rejected("old-generation", resolution_document(9))
        rejected(
            "wrong-query-receiver",
            {**resolution_document(10), "query_receiver_sha256": "0" * 64},
        )
        rejected(
            "wrong-clear-receiver",
            resolution_document(10),
            clear_receiver="0" * 64,
        )
        rejected(
            "wrong-ingest-receiver",
            {**resolution_document(10), "ingest_receiver_sha256": "0" * 64},
        )
        rejected(
            "wrong-committed-evidence",
            resolution_document(10, evidence=OLD_EVIDENCE),
        )
        rejected(
            "legacy-release-mismatch",
            resolution_document(10, release_id=OLD_RELEASE_ID),
            expected_release_id=RELEASE_ID,
        )
        rejected(
            "legacy-not-committed",
            resolution_document(
                10,
                accepted=9,
                active=9,
                evidence=OLD_EVIDENCE,
                release_id=OLD_RELEASE_ID,
                outcome="not-committed",
                runtime="healthy",
            ),
            expected_release_id=RELEASE_ID,
        )


def instrument_fsync(program: str) -> str:
    marker = "import stat\nimport sys\n"
    assert program.count(marker) == 1
    instrumentation = r'''import stat
import sys
_test_real_fsync = os.fsync
_test_real_unlink = os.unlink
_test_directory_fsyncs = 0
_test_clearing_unlinked = False
def _test_unlink(path, *args, **kwargs):
    global _test_clearing_unlinked
    result = _test_real_unlink(path, *args, **kwargs)
    if os.fsdecode(path).startswith(".clearing-pending-receipt-v5."):
        _test_clearing_unlinked = True
    return result
def _test_fsync(descriptor):
    global _test_directory_fsyncs, _test_clearing_unlinked
    kind = "D" if stat.S_ISDIR(os.fstat(descriptor).st_mode) else "F"
    with open(os.environ["FSYNC_TRACE"], "a", encoding="ascii") as stream:
        stream.write(kind + "\n")
    if kind == "D":
        _test_directory_fsyncs += 1
        fail_at = int(os.environ.get("FAIL_DIRECTORY_FSYNC_NUMBER", "0"))
        if _test_directory_fsyncs == fail_at:
            raise OSError("injected directory fsync failure")
        if (_test_clearing_unlinked
                and os.environ.get("FAIL_AFTER_CLEARING_UNLINK") == "1"):
            _test_clearing_unlinked = False
            raise OSError("injected clearing unlink fsync failure")
    return _test_real_fsync(descriptor)
os.unlink = _test_unlink
os.fsync = _test_fsync
'''
    return program.replace(marker, instrumentation, 1)


def instrument_tombstone_unlink_failure(program: str) -> str:
    marker = "import stat\nimport sys\n"
    assert program.count(marker) == 1
    instrumentation = r'''import stat
import sys
_test_real_unlink = os.unlink
def _test_unlink(path, *args, **kwargs):
    if os.fsdecode(path).startswith(".clearing-pending-receipt-v5."):
        raise OSError("injected tombstone unlink failure")
    return _test_real_unlink(path, *args, **kwargs)
os.unlink = _test_unlink
'''
    return program.replace(marker, instrumentation, 1)


def test_visible_state_is_repromoted_after_fsync_failure(sender_text: str) -> None:
    with tempfile.TemporaryDirectory(prefix="sync-receipt-fsync-") as raw:
        parent = Path(raw).resolve()
        pending_fixture = ReceiptFixture(parent, "pending", sender_text)
        selected = instrument_fsync(pending_fixture.program)
        first_trace = parent / "pending-first.trace"
        failed = pending_fixture.invoke(
            "create",
            "10",
            EVIDENCE,
            "",
            INGEST_RECEIVER,
            PROTOCOL,
            selected=selected,
            environment={
                **os.environ,
                "FSYNC_TRACE": str(first_trace),
                "FAIL_DIRECTORY_FSYNC_NUMBER": "1",
            },
        )
        assert failed.returncode != 0
        assert pending_fixture.pending.read_bytes() == canonical_json(pending_document())
        retry_trace = parent / "pending-retry.trace"
        retried = pending_fixture.invoke(
            "create",
            "10",
            EVIDENCE,
            "",
            INGEST_RECEIVER,
            PROTOCOL,
            selected=selected,
            environment={**os.environ, "FSYNC_TRACE": str(retry_trace)},
        )
        assert retried.returncode == 0, retried.stderr
        assert "D" in retry_trace.read_text(encoding="ascii").splitlines()

        resolution_fixture = ReceiptFixture(parent, "resolution", sender_text)
        resolution_fixture.create()
        selected = instrument_fsync(resolution_fixture.program)
        first_trace = parent / "resolution-first.trace"
        failed = resolution_fixture.invoke(
            "resolve-line",
            reconcile_receipt(10, 10, 10),
            "queried-after-ambiguous-ack",
            QUERY_RECEIVER,
            selected=selected,
            environment={
                **os.environ,
                "FSYNC_TRACE": str(first_trace),
                "FAIL_DIRECTORY_FSYNC_NUMBER": "1",
            },
        )
        assert failed.returncode != 0
        assert resolution_fixture.resolution.is_file()
        retry_trace = parent / "resolution-retry.trace"
        retried = resolution_fixture.invoke(
            "resolve-line",
            reconcile_receipt(10, 10, 10),
            "queried-after-ambiguous-ack",
            QUERY_RECEIVER,
            selected=selected,
            environment={**os.environ, "FSYNC_TRACE": str(retry_trace)},
        )
        assert retried.returncode == 0, retried.stderr
        assert "D" in retry_trace.read_text(encoding="ascii").splitlines()


def test_clear_is_compensated_and_tombstone_recovery_is_authorized(
    sender_text: str,
) -> None:
    with tempfile.TemporaryDirectory(prefix="sync-receipt-clearing-") as raw:
        parent = Path(raw).resolve()

        for name, failure in (
            ("rename-fsync", {"FAIL_DIRECTORY_FSYNC_NUMBER": "1"}),
            ("unlink-fsync", {"FAIL_AFTER_CLEARING_UNLINK": "1"}),
        ):
            fixture = ReceiptFixture(parent, name, sender_text)
            pending = fixture.create()
            resolved = fixture.invoke(
                "resolve-line",
                reconcile_receipt(10, 10, 10),
                "queried-after-ambiguous-ack",
                QUERY_RECEIVER,
            )
            assert resolved.returncode == 0, resolved.stderr
            resolution = fixture.resolution.read_bytes()
            trace = parent / f"{name}.trace"
            failed = fixture.invoke(
                "clear",
                QUERY_RECEIVER,
                selected=instrument_fsync(fixture.program),
                environment={
                    **os.environ,
                    "FSYNC_TRACE": str(trace),
                    **failure,
                },
            )
            assert failed.returncode != 0, name
            assert fixture.pending.read_bytes() == pending
            assert fixture.resolution.read_bytes() == resolution
            assert not list(
                fixture.root.glob(".clearing-pending-receipt-v5.*")
            ), name

        def tombstone(
            fixture: ReceiptFixture, payload: bytes, token: str = "a" * 32
        ) -> Path:
            path = fixture.root / f".clearing-pending-receipt-v5.{token}"
            path.write_bytes(payload)
            path.chmod(0o600)
            return path

        def resolved_fixture(
            name: str,
        ) -> tuple[ReceiptFixture, bytes, bytes]:
            fixture = ReceiptFixture(parent, name, sender_text)
            pending = fixture.create()
            resolved = fixture.invoke(
                "resolve-line",
                reconcile_receipt(10, 10, 10),
                "queried-after-ambiguous-ack",
                QUERY_RECEIVER,
            )
            assert resolved.returncode == 0, resolved.stderr
            return fixture, pending, fixture.resolution.read_bytes()

        unlink_failed, pending, resolution = resolved_fixture("unlink-failed")
        failed = unlink_failed.invoke(
            "clear",
            QUERY_RECEIVER,
            selected=instrument_tombstone_unlink_failure(unlink_failed.program),
        )
        assert failed.returncode != 0
        markers = list(
            unlink_failed.root.glob(".clearing-pending-receipt-v5.*")
        )
        assert len(markers) == 1 and markers[0].read_bytes() == pending
        assert unlink_failed.pending.read_bytes() == pending
        assert unlink_failed.resolution.read_bytes() == resolution
        recovered = unlink_failed.invoke("clean-stale")
        assert recovered.returncode == 0, recovered.stderr
        assert unlink_failed.pending.read_bytes() == pending
        assert not markers[0].exists()
        cleared = unlink_failed.invoke("clear", QUERY_RECEIVER)
        assert cleared.returncode == 0, cleared.stderr
        assert not unlink_failed.pending.exists()

        startup_unlink, pending, resolution = resolved_fixture(
            "startup-unlink-failed"
        )
        marker = tombstone(startup_unlink, pending)
        failed = startup_unlink.invoke(
            "clean-stale",
            selected=instrument_tombstone_unlink_failure(startup_unlink.program),
        )
        assert failed.returncode != 0
        assert startup_unlink.pending.read_bytes() == pending
        assert startup_unlink.resolution.read_bytes() == resolution
        assert marker.read_bytes() == pending
        retried = startup_unlink.invoke("clean-stale")
        assert retried.returncode == 0, retried.stderr
        assert startup_unlink.pending.read_bytes() == pending
        assert not marker.exists()

        multiple, pending, resolution = resolved_fixture("multiple-tombstones")
        first = tombstone(multiple, pending, "1" * 32)
        second = tombstone(multiple, pending, "2" * 32)
        rejected = multiple.invoke("clean-stale")
        assert rejected.returncode != 0
        assert multiple.pending.read_bytes() == pending
        assert multiple.resolution.read_bytes() == resolution
        assert first.read_bytes() == pending and second.read_bytes() == pending

        hardlinked, pending, resolution = resolved_fixture("hardlinked-tombstone")
        outside = parent / "hardlinked-tombstone-payload"
        outside.write_bytes(pending)
        outside.chmod(0o600)
        marker = hardlinked.root / (
            ".clearing-pending-receipt-v5." + "3" * 32
        )
        os.link(outside, marker)
        rejected = hardlinked.invoke("clean-stale")
        assert rejected.returncode != 0
        assert hardlinked.pending.read_bytes() == pending
        assert hardlinked.resolution.read_bytes() == resolution
        assert marker.read_bytes() == pending and marker.stat().st_nlink == 2

        symlinked, pending, resolution = resolved_fixture("symlinked-tombstone")
        outside = parent / "symlinked-tombstone-payload"
        outside.write_bytes(pending)
        outside.chmod(0o600)
        marker = symlinked.root / (
            ".clearing-pending-receipt-v5." + "4" * 32
        )
        marker.symlink_to(outside)
        rejected = symlinked.invoke("clean-stale")
        assert rejected.returncode != 0
        assert symlinked.pending.read_bytes() == pending
        assert symlinked.resolution.read_bytes() == resolution
        assert marker.is_symlink() and outside.read_bytes() == pending

        pending_present = ReceiptFixture(parent, "pending-present", sender_text)
        pending = pending_present.create()
        pending_present.resolution.write_bytes(
            canonical_json(resolution_document(10))
        )
        pending_present.resolution.chmod(0o600)
        marker = tombstone(pending_present, pending)
        recovered = pending_present.invoke("clean-stale")
        assert recovered.returncode == 0, recovered.stderr
        assert pending_present.pending.read_bytes() == pending
        assert not marker.exists()

        pending_absent = ReceiptFixture(parent, "pending-absent", sender_text)
        pending_absent.resolution.write_bytes(
            canonical_json(resolution_document(10))
        )
        pending_absent.resolution.chmod(0o600)
        marker = tombstone(
            pending_absent, canonical_json(pending_document())
        )
        recovered = pending_absent.invoke("clean-stale")
        assert recovered.returncode == 0, recovered.stderr
        assert not pending_absent.pending.exists() and not marker.exists()

        missing_resolution = ReceiptFixture(parent, "missing-resolution", sender_text)
        marker = tombstone(
            missing_resolution, canonical_json(pending_document())
        )
        rejected = missing_resolution.invoke("clean-stale")
        assert rejected.returncode != 0
        assert marker.read_bytes() == canonical_json(pending_document())

        mismatched_pending = ReceiptFixture(parent, "mismatched-pending", sender_text)
        pending = mismatched_pending.create()
        mismatched_pending.resolution.write_bytes(
            canonical_json(resolution_document(10))
        )
        mismatched_pending.resolution.chmod(0o600)
        different = canonical_json(
            {**pending_document(), "evidence_sha256": OLD_EVIDENCE}
        )
        marker = tombstone(mismatched_pending, different)
        rejected = mismatched_pending.invoke("clean-stale")
        assert rejected.returncode != 0
        assert mismatched_pending.pending.read_bytes() == pending
        assert marker.read_bytes() == different

        mismatched_resolution = ReceiptFixture(
            parent, "mismatched-resolution", sender_text
        )
        marker_payload = canonical_json(pending_document())
        marker = tombstone(mismatched_resolution, marker_payload)
        mismatched_resolution.resolution.write_bytes(
            canonical_json(resolution_document(9))
        )
        mismatched_resolution.resolution.chmod(0o600)
        rejected = mismatched_resolution.invoke("clean-stale")
        assert rejected.returncode != 0
        assert marker.read_bytes() == marker_payload

        unsafe = ReceiptFixture(parent, "unsafe-tombstone", sender_text)
        marker = tombstone(unsafe, canonical_json(pending_document()))
        marker.chmod(0o644)
        rejected = unsafe.invoke("clean-stale")
        assert rejected.returncode != 0
        assert marker.exists()


def test_resolution_preflight(sender_text: str) -> None:
    with tempfile.TemporaryDirectory(prefix="sync-resolution-preflight-") as raw:
        parent = Path(raw).resolve()
        valid = ReceiptFixture(parent, "valid-old", sender_text)
        valid.resolution.write_bytes(canonical_json(resolution_document(9)))
        valid.resolution.chmod(0o600)
        result = valid.invoke("pending")
        assert result.returncode == 0 and result.stdout == "none\n", result.stderr

        future = ReceiptFixture(parent, "future", sender_text)
        future_payload = canonical_json(resolution_document(11))
        future.resolution.write_bytes(future_payload)
        future.resolution.chmod(0o600)
        assert future.invoke("pending").returncode != 0
        assert future.resolution.read_bytes() == future_payload

        malformed = ReceiptFixture(parent, "malformed", sender_text)
        malformed_payload = canonical_json({**resolution_document(9), "extra": True})
        malformed.resolution.write_bytes(malformed_payload)
        malformed.resolution.chmod(0o600)
        assert malformed.invoke("pending").returncode != 0
        assert malformed.resolution.read_bytes() == malformed_payload

        float_version = ReceiptFixture(parent, "float-version", sender_text)
        float_version_payload = canonical_json(
            {**resolution_document(9), "version": 5.0}
        )
        float_version.resolution.write_bytes(float_version_payload)
        float_version.resolution.chmod(0o600)
        assert float_version.invoke("pending").returncode != 0
        assert float_version.resolution.read_bytes() == float_version_payload

        contradictory = ReceiptFixture(parent, "contradictory", sender_text)
        contradictory_payload = canonical_json(
            resolution_document(9, runtime="isolated")
        )
        contradictory.resolution.write_bytes(contradictory_payload)
        contradictory.resolution.chmod(0o600)
        assert contradictory.invoke("pending").returncode != 0
        assert contradictory.resolution.read_bytes() == contradictory_payload

        wrong_mode = ReceiptFixture(parent, "wrong-mode", sender_text)
        wrong_mode.resolution.write_bytes(canonical_json(resolution_document(9)))
        wrong_mode.resolution.chmod(0o644)
        assert wrong_mode.invoke("pending").returncode != 0

        symlinked = ReceiptFixture(parent, "symlink", sender_text)
        target = parent / "resolution-symlink-target"
        target.write_bytes(canonical_json(resolution_document(9)))
        target.chmod(0o600)
        symlinked.resolution.symlink_to(target)
        assert symlinked.invoke("pending").returncode != 0
        assert symlinked.resolution.is_symlink()

        hardlinked = ReceiptFixture(parent, "hardlink", sender_text)
        target = parent / "resolution-hardlink-target"
        target.write_bytes(canonical_json(resolution_document(9)))
        target.chmod(0o600)
        os.link(target, hardlinked.resolution)
        assert hardlinked.invoke("pending").returncode != 0
        assert target.stat().st_nlink == 2


def test_resolution_replay_is_monotonic(sender_text: str) -> None:
    with tempfile.TemporaryDirectory(prefix="sync-resolution-replay-") as raw:
        parent = Path(raw).resolve()

        newer = ReceiptFixture(parent, "replace-old", sender_text)
        newer.resolution.write_bytes(canonical_json(resolution_document(9)))
        newer.resolution.chmod(0o600)
        pending = newer.create()
        replaced = newer.invoke(
            "resolve-line",
            reconcile_receipt(10, 10, 10),
            "queried-after-ambiguous-ack",
            QUERY_RECEIVER,
        )
        assert replaced.returncode == 0, replaced.stderr
        assert newer.pending.read_bytes() == pending
        expected = canonical_json(resolution_document(10))
        assert newer.resolution.read_bytes() == expected

        same = newer.invoke(
            "resolve-line",
            reconcile_receipt(10, 10, 10),
            "startup-recovery",
            QUERY_RECEIVER,
        )
        assert same.returncode == 0, same.stderr
        assert same.stdout == "committed queried-after-ambiguous-ack 10\n"
        assert newer.pending.read_bytes() == pending
        assert newer.resolution.read_bytes() == expected

        for index, changed in enumerate(
            (
                reconcile_receipt(10, 10, 10, release_id=OLD_RELEASE_ID),
                reconcile_receipt(
                    9,
                    9,
                    9,
                    evidence=OLD_EVIDENCE,
                    release_id=OLD_RELEASE_ID,
                ),
            )
        ):
            rejected = newer.invoke(
                "resolve-line", changed, "startup-recovery", QUERY_RECEIVER
            )
            assert rejected.returncode != 0, index
            assert newer.pending.read_bytes() == pending
            assert newer.resolution.read_bytes() == expected


def test_resolve_shell_order_and_status(sender_text: str) -> None:
    capture_function = (
        "capture_control_stdout_hex() { "
        "od -An -v -tx1 | tr -d ' \\n'; }\n"
    )
    validate_function = "validate_resolution_stdout() { cat; }\n"
    function = shell_function(sender_text, "resolve_pending_receipt")

    def run(
        resolution: str,
        *,
        remote_payload: bytes | None = None,
        query_status: int = 0,
        log_status: int = 0,
        clear_status: int = 0,
    ) -> tuple[subprocess.CompletedProcess[str], list[str], bytes | None]:
        with tempfile.TemporaryDirectory(prefix="sync-resolve-shell-") as raw:
            root = Path(raw).resolve()
            calls = root / "calls"
            captured = root / "captured"
            remote_payload_path = root / "remote-payload"
            canonical_remote = reconcile_receipt(10, 10, 10).encode("ascii")
            remote_payload_path.write_bytes(remote_payload or canonical_remote)
            harness = (
                "set -euo pipefail\n"
                + capture_function
                + validate_function
                + function
                + "\nreceiver_control_query() {\n"
                + "  printf 'query:%s\\n' \"$1\" >> \"$CALLS\"\n"
                + "  /bin/cat \"$REMOTE_PAYLOAD_PATH\"\n"
                + "  return \"$QUERY_STATUS\"\n}\n"
                + "manage_receipt_state() {\n"
                + "  case $1 in\n"
                + "    resolve-hex) printf 'state:%s:%s:%s\\n' \"$1\" \"$3\" \"$4\" >> \"$CALLS\"; "
                + "printf '%s' \"$2\" > \"$CAPTURED\"; "
                + "[[ $2 == \"$EXPECTED_REMOTE_HEX\" ]] || return 41; "
                + "printf '%s' \"$RESOLUTION\" ;;\n"
                + "    clear) printf 'state:%s:%s\\n' \"$1\" \"$2\" >> \"$CALLS\"; "
                + "return \"$CLEAR_STATUS\" ;;\n"
                + "    *) return 1 ;;\n"
                + "  esac\n}\n"
                + "append_sync_authority_event() {\n"
                + "  printf 'log:%s:%s\\n' \"$1\" \"$2\" >> \"$CALLS\"\n"
                + "  return \"$LOG_STATUS\"\n}\n"
                + "REMOTE_RECEIVER_SHA256=$QUERY_RECEIVER\n"
                + "set +e\nresolve_pending_receipt queried-after-ambiguous-ack\n"
                + "status=$?\nset -e\nexit \"$status\"\n"
            )
            result = subprocess.run(
                ["/bin/bash", "-c", harness, "resolve-shell-test"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={
                    "PATH": "/usr/bin:/bin",
                    "CALLS": str(calls),
                    "CAPTURED": str(captured),
                    "CLEAR_STATUS": str(clear_status),
                    "LOG_STATUS": str(log_status),
                    "QUERY_RECEIVER": QUERY_RECEIVER,
                    "QUERY_STATUS": str(query_status),
                    "REMOTE_PAYLOAD_PATH": str(remote_payload_path),
                    "EXPECTED_REMOTE_HEX": canonical_remote.hex(),
                    "RESOLUTION": resolution,
                },
                check=False,
            )
            call_lines = calls.read_text(encoding="ascii").splitlines() if calls.exists() else []
            captured_bytes = captured.read_bytes() if captured.exists() else None
            return result, call_lines, captured_bytes

    committed, calls, captured = run(
        "committed queried-after-ambiguous-ack 10\n"
    )
    assert committed.returncode == 0, (committed.stderr, calls, captured)
    assert calls == [
        "query:--reconcile-receipt",
        f"state:resolve-hex:queried-after-ambiguous-ack:{QUERY_RECEIVER}",
        "log:completion-reconciled:10",
        f"state:clear:{QUERY_RECEIVER}",
    ]
    assert captured == reconcile_receipt(10, 10, 10).encode("ascii").hex().encode("ascii")

    not_committed, calls, _ = run(
        "not-committed queried-after-ambiguous-ack 10\n"
    )
    assert not_committed.returncode == 2
    assert calls == [
        "query:--reconcile-receipt",
        f"state:resolve-hex:queried-after-ambiguous-ack:{QUERY_RECEIVER}",
        "log:not-committed:10",
        f"state:clear:{QUERY_RECEIVER}",
    ]

    nul_query, calls, captured = run(
        "committed queried-after-ambiguous-ack 10\n",
        remote_payload=reconcile_receipt(10, 10, 10).encode("ascii") + b"\0",
    )
    assert nul_query.returncode != 0
    assert calls == [
        "query:--reconcile-receipt",
        f"state:resolve-hex:queried-after-ambiguous-ack:{QUERY_RECEIVER}",
    ]
    assert captured is not None and captured.endswith(b"00")

    malformed, calls, _ = run(
        "committed queried-after-ambiguous-ack 10\nunexpected\n"
    )
    assert malformed.returncode != 0
    assert not any(
        call.startswith("log:") or call.startswith("state:clear:") for call in calls
    )

    query_failed, calls, captured = run(
        "committed queried-after-ambiguous-ack 10\n", query_status=7
    )
    assert query_failed.returncode != 0
    assert calls == ["query:--reconcile-receipt"] and captured is None

    log_failed, calls, _ = run(
        "committed queried-after-ambiguous-ack 10\n", log_status=9
    )
    assert log_failed.returncode != 0
    assert calls[-1] == "log:completion-reconciled:10"
    assert not any(call.startswith("state:clear:") for call in calls)

    clear_failed, calls, _ = run(
        "committed queried-after-ambiguous-ack 10\n", clear_status=8
    )
    assert clear_failed.returncode != 0
    assert calls[-1] == f"state:clear:{QUERY_RECEIVER}"


def test_control_stdout_byte_encoding(sender_text: str) -> None:
    encoder = heredoc_after(sender_text, "capture_control_stdout_hex() {")
    validator = heredoc_after(sender_text, "validate_resolution_stdout() {")

    def run(program: str, payload: bytes) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            [sys.executable, "-I", "-c", program],
            input=payload,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    canonical = reconcile_receipt(10, 10, 10).encode("ascii")
    for payload in (
        canonical,
        canonical + b"\0",
        canonical.replace(b"\n", b"\r\n"),
        bytes(range(256)),
    ):
        encoded = run(encoder, payload)
        assert encoded.returncode == 0, encoded.stderr
        assert encoded.stdout == payload.hex().encode("ascii")
    oversized = run(encoder, b"x" * 65_537)
    assert oversized.returncode != 0 and oversized.stdout == b""

    valid_resolution = b"committed queried-after-ambiguous-ack 10\n"
    validated = run(validator, valid_resolution)
    assert validated.returncode == 0, validated.stderr
    assert validated.stdout == valid_resolution.rstrip(b"\n")
    for invalid in (
        valid_resolution.rstrip(b"\n"),
        valid_resolution.replace(b"\n", b"\r\n"),
        valid_resolution + b"\0",
        valid_resolution + b"unexpected\n",
    ):
        rejected = run(validator, invalid)
        assert rejected.returncode != 0, invalid
        assert rejected.stdout == b""


def test_reconcile_wrapper_invokes_one_exact_remote_command(sender_text: str) -> None:
    function = shell_function(sender_text, "receiver_control_query")
    timeout_prefix = "/usr/bin/timeout --signal=TERM --kill-after=5s 45s \\\n        "
    assert function.count(timeout_prefix) == 1
    function = function.replace(timeout_prefix, "", 1)
    with tempfile.TemporaryDirectory(prefix="sync-reconcile-wrapper-") as raw:
        root = Path(raw).resolve()
        helper = root / "ssh-stub"
        trace = root / "trace"
        helper.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' \"$#\" \"$@\" >> \"$TRACE\"\n"
            "printf 'ok\\n'\n",
            encoding="ascii",
        )
        helper.chmod(0o755)
        harness = (
            "set -euo pipefail\n"
            + function
            + "\nSSH=(\"$HELPER\")\n"
            + "REMOTE_RECEIVER=/usr/local/sbin/apply-shuzijun-sync\n"
            + "receiver_control_query --reconcile-receipt\n"
        )
        result = subprocess.run(
            ["/bin/bash", "-c", harness, "reconcile-wrapper-test"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={
                "PATH": "/usr/bin:/bin",
                "HELPER": str(helper),
                "TRACE": str(trace),
            },
            check=False,
        )
        assert result.returncode == 0, result.stderr
        assert result.stdout == "ok\n"
        assert trace.read_text(encoding="ascii").splitlines() == [
            "1",
            "sudo /usr/local/sbin/apply-shuzijun-sync --reconcile-receipt",
        ]


def test_legacy_entry_binds_release_and_reason(sender_text: str) -> None:
    start = sender_text.index('if [[ "$LEGACY_RECONCILE" -eq 1 ]]; then')
    end = sender_text.index("PENDING_RECEIPT=$(manage_receipt_state pending)", start)
    branch = sender_text[start:end]
    create = (
        'manage_receipt_state create "$LEGACY_GENERATION" "$LEGACY_EVIDENCE" \\\n'
        '        "$LEGACY_RELEASE_ID" "$LEGACY_INGEST_RECEIVER" "$SYNC_PROTOCOL"'
    )
    resolve = "resolve_pending_receipt legacy-v4-stdout-contamination"
    assert branch.count(create) == 1
    assert branch.count(resolve) == 1
    assert branch.index(create) < branch.index(resolve) < branch.index("exit 0")
    assert sender_text.count(resolve) == 1


def test_inline_and_ambiguous_ack_each_query_once(sender_text: str) -> None:
    capture_function = (
        "capture_control_stdout_hex() { "
        "od -An -v -tx1 | tr -d ' \\n'; }\n"
    )
    validate_function = "validate_resolution_stdout() { cat; }\n"
    function = shell_function(sender_text, "resolve_pending_receipt")
    tail_start = sender_text.index(
        'if [[ "$INGEST_STATUS" -eq 0 \\\n'
        '    && "$INGEST_RECEIPT_HEX" == "$EXPECTED_INGEST_RECEIPT_HEX" ]]; then'
    )
    tail = sender_text[tail_start:]
    inline_ack = (
        f"sync-applied generation=10 receiver-sha256={QUERY_RECEIVER} "
        f"protocol={PROTOCOL} cache=flushed signed=true uploads-only=true\n"
    ).encode("ascii")
    remote_receipt = reconcile_receipt(10, 10, 10)

    def run(
        acknowledgement: bytes,
        ingest_status: int,
        *,
        outcome: str = "committed",
    ) -> tuple[subprocess.CompletedProcess[str], list[str]]:
        with tempfile.TemporaryDirectory(prefix="sync-ack-query-count-") as raw:
            calls = Path(raw).resolve() / "calls"
            harness = (
                "set -euo pipefail\n"
                + capture_function
                + validate_function
                + function
                + "\nreceiver_control_query() {\n"
                + "  printf 'query:%s\\n' \"$1\" >> \"$CALLS\"\n"
                + "  printf '%s' \"$REMOTE_PAYLOAD\"\n"
                + "}\n"
                + "manage_receipt_state() {\n"
                + "  if [[ $1 == resolve-hex ]]; then\n"
                + "    printf 'state:%s:%s:%s\\n' \"$1\" \"$3\" \"$4\" >> \"$CALLS\"\n"
                + "    printf '%s %s 10\\n' \"$OUTCOME\" \"$3\"\n"
                + "  elif [[ $1 == clear ]]; then\n"
                + "    printf 'state:%s:%s\\n' \"$1\" \"$2\" >> \"$CALLS\"\n"
                + "  else\n"
                + "    return 1\n"
                + "  fi\n"
                + "}\n"
                + "append_sync_authority_event() {\n"
                + "  printf 'log:%s:%s\\n' \"$1\" \"$2\" >> \"$CALLS\"\n"
                + "}\n"
                + "GENERATION=10\n"
                + "REMOTE_RECEIVER_SHA256=$QUERY_RECEIVER\n"
                + "SYNC_PROTOCOL=$PROTOCOL\n"
                + "INGEST_RECEIPT_HEX=$ACKNOWLEDGEMENT_HEX\n"
                + "EXPECTED_INGEST_RECEIPT_HEX=$EXPECTED_ACK_HEX\n"
                + "INGEST_STATUS=$INGEST_EXIT\n"
                + tail
            )
            result = subprocess.run(
                ["/bin/bash", "-c", harness, "ack-query-count-test"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={
                    "PATH": "/usr/bin:/bin",
                    "ACKNOWLEDGEMENT_HEX": acknowledgement.hex(),
                    "CALLS": str(calls),
                    "EXPECTED_ACK_HEX": inline_ack.hex(),
                    "INGEST_EXIT": str(ingest_status),
                    "OUTCOME": outcome,
                    "PROTOCOL": PROTOCOL,
                    "QUERY_RECEIVER": QUERY_RECEIVER,
                    "REMOTE_PAYLOAD": remote_receipt,
                },
                check=False,
            )
            call_lines = calls.read_text(encoding="ascii").splitlines()
            return result, call_lines

    exact, calls = run(inline_ack, 0)
    assert exact.returncode == 0, exact.stderr
    assert calls.count("query:--reconcile-receipt") == 1
    assert calls == [
        "query:--reconcile-receipt",
        f"state:resolve-hex:inline-ack:{QUERY_RECEIVER}",
        "log:completion:10",
        f"state:clear:{QUERY_RECEIVER}",
    ]

    polluted, calls = run(b"backup-path\n" + inline_ack, 0)
    assert polluted.returncode == 0, polluted.stderr
    assert calls == [
        "query:--reconcile-receipt",
        f"state:resolve-hex:queried-after-ambiguous-ack:{QUERY_RECEIVER}",
        "log:completion-reconciled:10",
        f"state:clear:{QUERY_RECEIVER}",
    ]

    nul_polluted, calls = run(inline_ack + b"\0", 0)
    assert nul_polluted.returncode == 0, nul_polluted.stderr
    assert calls == [
        "query:--reconcile-receipt",
        f"state:resolve-hex:queried-after-ambiguous-ack:{QUERY_RECEIVER}",
        "log:completion-reconciled:10",
        f"state:clear:{QUERY_RECEIVER}",
    ]

    nonzero, calls = run(inline_ack, 7)
    assert nonzero.returncode == 0, nonzero.stderr
    assert calls == [
        "query:--reconcile-receipt",
        f"state:resolve-hex:queried-after-ambiguous-ack:{QUERY_RECEIVER}",
        "log:completion-reconciled:10",
        f"state:clear:{QUERY_RECEIVER}",
    ]

    not_committed, calls = run(b"missing-ack", 7, outcome="not-committed")
    assert not_committed.returncode != 0
    assert calls == [
        "query:--reconcile-receipt",
        f"state:resolve-hex:queried-after-ambiguous-ack:{QUERY_RECEIVER}",
        "log:not-committed:10",
        f"state:clear:{QUERY_RECEIVER}",
    ]


def test_receiver_canonical_output_and_stdout_firewall(receiver_text: str) -> None:
    start = receiver_text.index(
        'if [[ $# -eq 1 && "$1" == --reconcile-receipt ]]; then'
    )
    end = receiver_text.index(
        'if [[ $# -eq 2 && "$1" == --bootstrap-state ]]; then', start
    )
    branch = receiver_text[start:end]
    assert branch.count("sync-reconcile-v5 accepted=%s active=%s committed=%s") == 1

    def run(
        state: str,
        state_status: int = 0,
        *,
        fail_at: str = "",
    ) -> tuple[subprocess.CompletedProcess[bytes], list[str]]:
        harness = (
            "set -euo pipefail\n"
            "finish_receiver() { status=$1; trap - EXIT; exit \"$status\"; }\n"
            "gate() { printf '%s\\n' \"$1\" >> \"$CALLS\"; [[ $FAIL_AT != \"$1\" ]]; }\n"
            "validate_fpm_guard_unit() { gate validate_fpm_guard_unit; }\n"
            "validate_allowed_signers() { gate validate_allowed_signers; }\n"
            "clean_stale_state_temporaries() { gate clean_stale_state_temporaries; }\n"
            "clean_stale_rollback_sql() { gate clean_stale_rollback_sql; }\n"
            "verify_webroot_security() { gate verify_webroot_security && printf 'webroot-security: passed\\n'; }\n"
            "run_receiver_recovery_and_baseline() { gate run_receiver_recovery_and_baseline && printf 'recovery-noise\\n'; }\n"
            "clean_stale_claims() { gate clean_stale_claims && printf 'claim-noise\\n'; }\n"
            "manage_uploads_transaction() { gate manage_uploads_transaction || return 1; printf '%s' \"$INTERNAL_STATE\"; return \"$STATE_STATUS\"; }\n"
            "validate_reconcile_state_stdout() { cat; }\n"
            "validate_fpm_guard_commit_matches_accepted() { gate validate_fpm_guard_commit_matches_accepted; }\n"
            "verify_fpm_ready() { gate verify_fpm_ready; }\n"
            "probe_standby_runtime() { gate probe_standby_runtime; }\n"
            "generation_is_less() { gate generation_is_less && (( $1 < $2 )); }\n"
            "isolate_failed_fpm() { gate isolate_failed_fpm; }\n"
            f"SELF_SHA256={QUERY_RECEIVER}\n"
            f"SYNC_PROTOCOL={PROTOCOL}\n"
            + branch
        )
        with tempfile.TemporaryDirectory(prefix="sync-receiver-reconcile-") as raw:
            calls = Path(raw).resolve() / "calls"
            result = subprocess.run(
                ["/bin/bash", "-c", harness, "reconcile-receiver-test", "--reconcile-receipt"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={
                    "PATH": "/usr/bin:/bin",
                    "CALLS": str(calls),
                    "FAIL_AT": fail_at,
                    "INTERNAL_STATE": state,
                    "STATE_STATUS": str(state_status),
                },
                check=False,
            )
            call_lines = (
                calls.read_text(encoding="ascii").splitlines()
                if calls.exists()
                else []
            )
            return result, call_lines

    healthy_state = f"10 10 10 {EVIDENCE} {RELEASE_ID}\n"
    healthy, calls = run(healthy_state)
    assert healthy.returncode == 0, healthy.stderr
    assert healthy.stdout == reconcile_receipt(10, 10, 10).encode("ascii")
    healthy_calls = [
        "validate_fpm_guard_unit",
        "validate_allowed_signers",
        "clean_stale_state_temporaries",
        "clean_stale_rollback_sql",
        "verify_webroot_security",
        "run_receiver_recovery_and_baseline",
        "clean_stale_claims",
        "manage_uploads_transaction",
        "validate_fpm_guard_commit_matches_accepted",
        "verify_fpm_ready",
        "probe_standby_runtime",
    ]
    assert calls == healthy_calls

    isolated_state = f"10 9 9 {OLD_EVIDENCE} {OLD_RELEASE_ID}\n"
    isolated, calls = run(isolated_state)
    assert isolated.returncode == 0, isolated.stderr
    assert isolated.stdout == reconcile_receipt(
        10,
        9,
        9,
        evidence=OLD_EVIDENCE,
        release_id=OLD_RELEASE_ID,
        runtime="isolated",
    ).encode("ascii")
    assert calls == healthy_calls[:8] + ["generation_is_less", "isolate_failed_fpm"]

    polluted_internal, _ = run(healthy_state + "unexpected\n")
    assert polluted_internal.returncode != 0
    assert polluted_internal.stdout == b""

    output_then_failure, _ = run(healthy_state, state_status=7)
    assert output_then_failure.returncode != 0
    assert output_then_failure.stdout == b""

    for gate_name in healthy_calls:
        rejected, calls = run(healthy_state, fail_at=gate_name)
        assert rejected.returncode != 0, gate_name
        assert rejected.stdout == b"", gate_name
        assert calls[-1] == gate_name
    for gate_name in ("generation_is_less", "isolate_failed_fpm"):
        rejected, calls = run(isolated_state, fail_at=gate_name)
        assert rejected.returncode != 0, gate_name
        assert rejected.stdout == b"", gate_name
        assert calls[-1] == gate_name


def test_receiver_recovery_stdout_is_suppressed(receiver_text: str) -> None:
    rollback = shell_function(receiver_text, "rollback_incomplete_transaction")
    assert "verify_webroot_security >/dev/null || return 1" in rollback
    ingest = receiver_text[receiver_text.index('[[ $# -eq 1 && "$1" == --ingest ]]'):]
    assert "run_receiver_recovery_and_baseline >/dev/null" in ingest
    assert "clean_stale_claims >/dev/null" in ingest
    assert 'retire_backup_history "$DEST" >/dev/null' in ingest

    harness = (
        "set -euo pipefail\n"
        + rollback
        + "\nmanage_uploads_transaction() {\n"
        + "  case $1 in\n"
        + "    inspect) printf '10 9 database-imported /backup\\n' ;;\n"
        + "    rollback-media) printf 'database\\n' ;;\n"
        + "    finish-rollback) : ;;\n"
        + "    *) return 1 ;;\n"
        + "  esac\n}\n"
        + "isolate_failed_fpm() { :; }\n"
        + "restore_database_from_backup() { :; }\n"
        + "verify_webroot_security() { printf 'webroot-security: passed\\n'; }\n"
        + "validate_database_markers() { :; }\n"
        + "rollback_incomplete_transaction\n"
    )
    result = subprocess.run(
        ["/bin/bash", "-c", harness, "rollback-stdout-test"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={"PATH": "/usr/bin:/bin"},
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout == ""


def main() -> None:
    sender_text = SENDER.read_text(encoding="utf-8")
    receiver_text = RECEIVER.read_text(encoding="utf-8")
    test_pending_state(sender_text)
    test_reconciliation_matrix(sender_text)
    test_clear_requires_exact_durable_resolution(sender_text)
    test_visible_state_is_repromoted_after_fsync_failure(sender_text)
    test_clear_is_compensated_and_tombstone_recovery_is_authorized(sender_text)
    test_resolution_preflight(sender_text)
    test_resolution_replay_is_monotonic(sender_text)
    test_resolve_shell_order_and_status(sender_text)
    test_control_stdout_byte_encoding(sender_text)
    test_reconcile_wrapper_invokes_one_exact_remote_command(sender_text)
    test_legacy_entry_binds_release_and_reason(sender_text)
    test_inline_and_ambiguous_ack_each_query_once(sender_text)
    test_receiver_canonical_output_and_stdout_firewall(receiver_text)
    test_receiver_recovery_stdout_is_suppressed(receiver_text)
    print("sync-receipt-recovery-contract-test: passed")


if __name__ == "__main__":
    main()
