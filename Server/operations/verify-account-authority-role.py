#!/usr/bin/python3 -I
"""Read-only verifier for the fixed, server-owned account-authority marker."""

from __future__ import annotations

import os
import stat
import sys
from pathlib import Path


ROLE_PATH = Path("/etc/shuzijun/account-authority-role")
PARENT_CHAIN = (Path("/etc"), Path("/etc/shuzijun"))
VALID_PAYLOADS = {"authority": b"authority\n", "standby": b"standby\n"}


class VerificationError(ValueError):
    pass


def verify_payload(payload: bytes, expected_role: str) -> None:
    expected = VALID_PAYLOADS.get(expected_role)
    if expected is None:
        raise VerificationError("expected role must be authority or standby")
    if payload != expected:
        raise VerificationError(
            "account-authority marker must contain exactly the expected role plus one LF"
        )


def _validate_parent(path: Path) -> None:
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise VerificationError(f"cannot validate fixed marker parent {path}: {error.strerror}") from error
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or path.is_symlink()
        or resolved != path
        or metadata.st_uid != 0
        or metadata.st_gid != 0
        or stat.S_IMODE(metadata.st_mode) != 0o755
    ):
        raise VerificationError(
            f"marker parent must be canonical root:root mode 0755: {path}"
        )


def _read_fixed_marker() -> bytes:
    for parent in PARENT_CHAIN:
        _validate_parent(parent)

    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(ROLE_PATH, flags)
    except OSError as error:
        raise VerificationError(f"cannot safely open fixed authority marker: {error.strerror}") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise VerificationError("account-authority marker must be a regular file")
        if metadata.st_uid != 0 or metadata.st_gid != 0:
            raise VerificationError("account-authority marker must be owned by root:root")
        if stat.S_IMODE(metadata.st_mode) != 0o644:
            raise VerificationError("account-authority marker mode must be exactly 0644")
        if metadata.st_nlink != 1:
            raise VerificationError("account-authority marker must not be hard-linked")
        if metadata.st_size not in {8, 10}:
            raise VerificationError("account-authority marker has an invalid size")
        payload = os.read(descriptor, 16)
        if os.read(descriptor, 1):
            raise VerificationError("account-authority marker exceeds the fixed size")
        return payload
    finally:
        os.close(descriptor)


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] not in VALID_PAYLOADS:
        print("usage: verify-shuzijun-account-authority-role authority|standby", file=sys.stderr)
        return 2
    if os.geteuid() != 0:
        print("account-authority-role: must run as root", file=sys.stderr)
        return 1
    try:
        verify_payload(_read_fixed_marker(), argv[1])
    except VerificationError as error:
        print(f"account-authority-role: {error}", file=sys.stderr)
        return 1
    print(f"account-authority-role: verified role={argv[1]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
