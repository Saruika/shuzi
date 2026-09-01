import hashlib
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


WRAPPER = Path("Server/operations/verify-webroot-security")
CHECKER = Path("Server/operations/verify-nginx-server-block-contract.py")


def transformed_wrapper(root: Path, checker: Path, expected_hash: str) -> Path:
    """Build a Linux-only fixture without adding a production path override."""
    source = WRAPPER.read_text(encoding="utf-8")
    source = source.replace(
        "readonly nginx_contract_checker=/usr/local/sbin/verify-nginx-server-block-contract.py",
        f"readonly nginx_contract_checker={checker}",
    )
    source = source.replace(
        "readonly nginx_contract_checker_sha256="
        + hashlib.sha256(CHECKER.read_bytes()).hexdigest(),
        f"readonly nginx_contract_checker_sha256={expected_hash}",
    )
    uid, gid = os.getuid(), os.getgid()
    source = source.replace(
        '"$nginx_contract_checker" == /usr/local/sbin/verify-nginx-server-block-contract.py',
        f'"$nginx_contract_checker" == {checker}',
    )
    source = source.replace("'0:0:1:755'", f"'{uid}:{gid}:1:755'")
    source = source.replace(
        "for parent in /usr /usr/local /usr/local/sbin; do",
        f'for parent in "{root}"; do',
    )
    source = source.replace(
        '"$(stat -c \'%u:%g\' "$parent")" == \'0:0\'',
        f'"$(stat -c \'%u:%g\' "$parent")" == \'{uid}:{gid}\'',
    )
    wrapper = root / "verify-webroot-security"
    wrapper.write_text(source, encoding="utf-8")
    wrapper.chmod(0o755)
    return wrapper


def run_fixture(kind: str) -> tuple[subprocess.CompletedProcess[str], bool]:
    with tempfile.TemporaryDirectory(prefix="yishu-checker-trust-") as temp:
        root = Path(temp).resolve()
        root.chmod(0o700)
        sentinel = root / "executed"
        target = root / "checker-target.py"
        target.write_text(
            "#!/usr/bin/python3\n"
            "from pathlib import Path\n"
            f"Path({str(sentinel)!r}).write_text('executed', encoding='utf-8')\n",
            encoding="utf-8",
        )
        target.chmod(0o755)
        expected_hash = hashlib.sha256(target.read_bytes()).hexdigest()
        checker = root / "checker.py"
        if kind == "symlink":
            checker.symlink_to(target)
        else:
            checker.write_bytes(target.read_bytes())
            checker.chmod(0o777 if kind == "world-writable" else 0o755)
        if kind == "hash-mismatch":
            expected_hash = "0" * 64

        wrapper = transformed_wrapper(root, checker, expected_hash)
        # Negative cases must fail in the initial trust gate, before any
        # caller-controlled site/config path is inspected or checker code runs.
        result = subprocess.run(
            [str(wrapper), str(root / "missing-site")],
            capture_output=True,
            text=True,
        )
        return result, sentinel.exists()


def main() -> None:
    text = WRAPPER.read_text(encoding="utf-8")
    checker_hash = hashlib.sha256(CHECKER.read_bytes()).hexdigest()
    assert "PATH=/usr/sbin:/usr/bin:/sbin:/bin" in text
    assert "unset CDPATH ENV PYTHONPATH PYTHONHOME" in text
    assert "readonly nginx_contract_checker=/usr/local/sbin/verify-nginx-server-block-contract.py" in text
    assert f"readonly nginx_contract_checker_sha256={checker_hash}" in text
    trust = text[text.index("open_reviewed_nginx_checker() {"):text.index("run_reviewed_nginx_checker() {")]
    for guard in (
        "realpath -e",
        "! -L",
        "stat -c '%u:%g:%h:%a'",
        "0:0:1:755",
        "for parent in /usr /usr/local /usr/local/sbin",
        "writable by a non-root identity",
        'exec 9<"$nginx_contract_checker"',
        "stat -Lc '%u:%g:%h:%a'",
        'sha256sum "$nginx_contract_checker_fd"',
        "Nginx checker review hash mismatch",
    ):
        assert guard in trust
    runner = text[text.index("run_reviewed_nginx_checker() {"):text.index("# Establish the checker trust chain")]
    assert '/usr/bin/python3 -I "$nginx_contract_checker_fd"' in runner
    assert 'python3 "$nginx_contract_checker"' not in text
    assert text.index("open_reviewed_nginx_checker\n") < text.index('test -d "$site_root"')

    if sys.platform.startswith("linux"):
        expectations = {
            "symlink": "path or metadata is unsafe",
            "world-writable": "path or metadata is unsafe",
            "hash-mismatch": "review hash mismatch",
        }
        for kind, error in expectations.items():
            result, executed = run_fixture(kind)
            assert result.returncode != 0, (kind, result.stdout, result.stderr)
            assert error in result.stderr, (kind, result.stderr)
            assert not executed, f"{kind} checker executed before trust rejection"

    print("webroot-verifier-trust-contract-test: passed")


if __name__ == "__main__":
    main()
