#!/usr/bin/env python3
"""Validate the active Shuzijun Nginx virtual-host security contract.

This checker intentionally performs no network requests.  It parses the
enabled Nginx source directly so comments, quoted strings and nested blocks
cannot make a textual grep appear to satisfy the contract.
"""

from __future__ import annotations

import argparse
import glob
import grp
import os
import pwd
import re
import stat
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence


WWW_HOST = "www.shuzijun.com.cn"
IMG_HOST = "img.shuzijun.com.cn"
TLS_443_ENDPOINT_PATTERN = re.compile(
    r"(?:443|\[[^\]\s]+\]:443|[^:\s]+:443)\Z", re.IGNORECASE
)
SENSITIVE_EXACT_URI_PATTERNS = (
    re.compile(r"^/wp-content/.*\.php(?:$|/)", re.IGNORECASE),
    re.compile(r"^/images/.*\.php(?:$|/)", re.IGNORECASE),
    re.compile(
        r"(?:^|/)(?:wp-config\.php(?:$|[^/]+)|[^/]+\.php[^/]+$|"
        r"[^/]+\.(?:bak|backup|old|orig|save|swp|tmp|copy|disabled|corrupt|"
        r"corrupted|fixbak)(?:$|[._~-])|[^/]+\.before-[^/]+$|[^/]+~$)",
        re.IGNORECASE,
    ),
    re.compile(
        r"(?:^|/)(?:\.env(?:\.[^/]*)?|\.(?:git|svn|hg)(?:/|$)|"
        r"(?:composer\.(?:json|lock)|auth\.json|package(?:-lock)?\.json|"
        r"yarn\.lock|pnpm-lock\.yaml)$|[^/]+\.(?:sql(?:\.gz)?|dump|pem|"
        r"key|p8|p12|pfx|jks|log|zip|tar|tar\.gz|tgz|7z|rar)$|"
        r"(?:credentials|service-account)[^/]*\.json$)",
        re.IGNORECASE,
    ),
)
MAX_CONFIG_TOKENS = 262_144
MetadataIdentity = tuple[int, int, int, int, int, int, int, int, int]


class ContractError(Exception):
    """A fail-closed contract violation."""


@dataclass(frozen=True)
class Token:
    value: str
    line: int
    symbol: bool = False


@dataclass(frozen=True)
class Directive:
    name: str
    args: tuple[str, ...]
    children: tuple["Directive", ...] | None
    line: int


@dataclass(frozen=True)
class EffectiveDirective:
    """A directive after safe, textual expansion of local include files."""

    name: str
    args: tuple[str, ...]
    children: tuple["EffectiveDirective", ...] | None
    line: int
    source: Path
    reviewed_include: bool = False
    reviewed_origin: str | None = None


def nginx_escape_value(escaped: str) -> str:
    """Apply the escape rules used by nginx's ngx_conf_read_token()."""

    translated = {"t": "\t", "r": "\r", "n": "\n"}
    if escaped in translated:
        return translated[escaped]
    if escaped in ('"', "'", "\\"):
        return escaped
    # Nginx preserves the slash for every other escaped byte.  Treating
    # ``\x`` as ``x`` would let the checker inspect a different include or
    # document root from the one nginx actually opens.
    return "\\" + escaped


def tokenize(text: str, source: Path) -> list[Token]:
    """Tokenize enough of the Nginx grammar to locate directives reliably.

    A structural brace may be adjacent to a directive name.  A brace in a
    regular expression therefore has to be quoted, exactly as nginx requires;
    a ${variable} brace remains part of its token.  Comments are recognized
    only outside quoted strings.
    """

    tokens: list[Token] = []
    index = 0
    line = 1
    length = len(text)

    def emit(token: Token) -> None:
        if len(tokens) >= MAX_CONFIG_TOKENS:
            raise ContractError(f"{source}: token count exceeds the reviewed limit")
        tokens.append(token)

    while index < length:
        char = text[index]
        if char in " \t\r":
            index += 1
            continue
        if char == "\n":
            line += 1
            index += 1
            continue
        if char == "#":
            newline = text.find("\n", index)
            if newline == -1:
                break
            index = newline
            continue
        if char in ";{}":
            emit(Token(char, line, True))
            index += 1
            continue
        if char in "'\"":
            quote = char
            token_line = line
            index += 1
            value: list[str] = []
            while index < length:
                char = text[index]
                if char == "\\":
                    if index + 1 >= length:
                        raise ContractError(
                            f"{source}:{token_line}: unterminated quoted escape"
                        )
                    escaped = text[index + 1]
                    if escaped == "\n":
                        line += 1
                    value.append(nginx_escape_value(escaped))
                    index += 2
                    continue
                if char == quote:
                    index += 1
                    break
                if char == "\n":
                    line += 1
                value.append(char)
                index += 1
            else:
                raise ContractError(f"{source}:{token_line}: unterminated quote")
            emit(Token("".join(value), token_line))
            continue

        token_line = line
        value = []
        while index < length:
            char = text[index]
            if char in " \t\r\n;#":
                break
            if char == "\\":
                if index + 1 >= length:
                    raise ContractError(
                        f"{source}:{token_line}: unterminated unquoted escape"
                    )
                escaped = text[index + 1]
                if escaped == "\n":
                    line += 1
                value.append(nginx_escape_value(escaped))
                index += 2
                continue
            if char == "{" and value and value[-1] == "$":
                closing = text.find("}", index + 1)
                if closing == -1:
                    raise ContractError(
                        f"{source}:{token_line}: unterminated variable expansion"
                    )
                value.append(text[index : closing + 1])
                index = closing + 1
                continue
            if char in "{}":
                break
            value.append(char)
            index += 1
        if not value:
            raise ContractError(f"{source}:{line}: cannot tokenize {text[index:index + 8]!r}")
        emit(Token("".join(value), token_line))

    return tokens


def parse(text: str, source: Path) -> tuple[Directive, ...]:
    tokens = tokenize(text, source)
    position = 0
    max_block_depth = 64

    def parse_scope(expect_close: bool, depth: int = 0) -> tuple[Directive, ...]:
        nonlocal position
        if depth > max_block_depth:
            raise ContractError(f"{source}: block nesting exceeds the reviewed limit")
        directives: list[Directive] = []
        while position < len(tokens):
            if tokens[position].value == "}":
                if not expect_close:
                    raise ContractError(
                        f"{source}:{tokens[position].line}: unexpected closing brace"
                    )
                position += 1
                return tuple(directives)
            start = tokens[position]
            if start.symbol:
                raise ContractError(
                    f"{source}:{start.line}: expected directive, got {start.value!r}"
                )
            position += 1
            args: list[str] = []
            while position < len(tokens) and tokens[position].value not in (";", "{", "}"):
                args.append(tokens[position].value)
                position += 1
            if position >= len(tokens):
                raise ContractError(f"{source}:{start.line}: unterminated directive {start.value}")
            terminator = tokens[position]
            if terminator.value == "}":
                raise ContractError(
                    f"{source}:{start.line}: directive {start.value} is missing ';' or '{{'"
                )
            position += 1
            if terminator.value == ";":
                directives.append(Directive(start.value, tuple(args), None, start.line))
            else:
                children = parse_scope(True, depth + 1)
                directives.append(Directive(start.value, tuple(args), children, start.line))
        if expect_close:
            raise ContractError(f"{source}: unclosed block")
        return tuple(directives)

    result = parse_scope(False)
    if position != len(tokens):
        raise ContractError(f"{source}: trailing parser state")
    return result


def descendants(directive: Directive) -> Iterable[Directive]:
    if directive.children is None:
        return
    for child in directive.children:
        yield child
        yield from descendants(child)


def direct(directive: Directive, name: str) -> list[Directive]:
    return [
        child
        for child in (directive.children or ())
        if child.name.lower() == name.lower()
    ]


def directive_signature(directive: Directive) -> tuple[object, ...]:
    return (
        directive.name,
        directive.args,
        None
        if directive.children is None
        else tuple(directive_signature(child) for child in directive.children),
    )


DENY_404_BODY = (
    ("access_log", ("off",), None),
    ("log_not_found", ("off",), None),
    ("return", ("404",), None),
)

EXPECTED_SENSITIVE_SIGNATURE = (
    (
        "location",
        (
            "~*",
            r"(?:^|/)(?:wp-config\.php(?:$|[^/]+)|[^/]+\.php[^/]+$|"
            r"[^/]+\.(?:bak|backup|old|orig|save|swp|tmp|copy|disabled|"
            r"corrupt|corrupted|fixbak)(?:$|[._~-])|[^/]+\.before-[^/]+$|"
            r"[^/]+~$)",
        ),
        DENY_404_BODY,
    ),
    ("location", ("~*", r"^/wp-content/.*\.php(?:$|/)"), DENY_404_BODY),
    ("location", ("~*", r"^/images/.*\.php(?:$|/)"), DENY_404_BODY),
    (
        "location",
        (
            "~*",
            r"(?:^|/)(?:\.env(?:\.[^/]*)?|\.(?:git|svn|hg)(?:/|$)|"
            r"(?:composer\.(?:json|lock)|auth\.json|package(?:-lock)?\.json|"
            r"yarn\.lock|pnpm-lock\.yaml)$|[^/]+\.(?:sql(?:\.gz)?|dump|pem|"
            r"key|p8|p12|pfx|jks|log|zip|tar|tar\.gz|tgz|7z|rar)$|"
            r"(?:credentials|service-account)[^/]*\.json$)",
        ),
        DENY_404_BODY,
    ),
)

EXPECTED_LEGACY_SIGNATURE = (
    ("location", ("=", "/images"), (("return", ("308", "/images/"), None),)),
    (
        "location",
        (
            "~*",
            r"^/images/([A-Za-z0-9][A-Za-z0-9._-]*\."
            r"(?:jpg|jpeg|png|gif|webp|avif|ico|svg))$",
        ),
        (
            (
                "alias",
                (
                    "/var/www/html/shuzijun.com.cn/"
                    "wp-content/uploads/hero-images/$1",
                ),
                None,
            ),
            ("expires", ("365d",), None),
            (
                "add_header",
                ("Cache-Control", "public, max-age=31536000, immutable"),
                None,
            ),
            ("add_header", ("X-Content-Type-Options", "nosniff", "always"), None),
            ("add_header", ("Timing-Allow-Origin", "*", "always"), None),
            (
                "add_header",
                ("Cross-Origin-Resource-Policy", "cross-origin", "always"),
                None,
            ),
            ("access_log", ("off",), None),
        ),
    ),
    (
        "location",
        ("/images/",),
        (
            ("access_log", ("off",), None),
            ("log_not_found", ("off",), None),
            ("return", ("404",), None),
        ),
    ),
)


def validate_reviewed_snippet(
    kind: str, document: Sequence[Directive], source: Path
) -> None:
    expected = (
        EXPECTED_SENSITIVE_SIGNATURE
        if kind == "sensitive"
        else EXPECTED_LEGACY_SIGNATURE
    )
    actual = tuple(directive_signature(item) for item in document)
    if actual != expected:
        if kind == "sensitive" and EXPECTED_SENSITIVE_SIGNATURE[1] not in actual:
            raise ContractError(
                f"{source}: sensitive snippet semantic content drifted; "
                "direct wp-content PHP deny rule is missing"
            )
        raise ContractError(f"{source}: {kind} snippet semantic content drifted")


def effective_descendants(
    directive: EffectiveDirective,
) -> Iterable[EffectiveDirective]:
    if directive.children is None:
        return
    for child in directive.children:
        yield child
        yield from effective_descendants(child)


def effective_direct(
    directive: EffectiveDirective, name: str
) -> list[EffectiveDirective]:
    return [
        child
        for child in (directive.children or ())
        if child.name.lower() == name.lower()
    ]


def parse_identity(value: str) -> tuple[int, int]:
    try:
        user_value, group_value = value.split(":", 1)
    except ValueError as error:
        raise ContractError(f"invalid owner identity {value!r}") from error
    try:
        uid = int(user_value) if user_value.isdigit() else pwd.getpwnam(user_value).pw_uid
        gid = int(group_value) if group_value.isdigit() else grp.getgrnam(group_value).gr_gid
    except (KeyError, ValueError) as error:
        raise ContractError(f"unknown owner identity {value!r}") from error
    return uid, gid


def metadata_identity(metadata: os.stat_result) -> MetadataIdentity:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_gid,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def require_secure_file(path: Path, owner: tuple[int, int], label: str) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError as error:
        raise ContractError(f"{label} is missing: {path}") from error
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise ContractError(f"{label} must be a regular non-symlink file: {path}")
    if (metadata.st_uid, metadata.st_gid) != owner:
        raise ContractError(f"{label} has unsafe ownership: {path}")
    if stat.S_IMODE(metadata.st_mode) & 0o022:
        raise ContractError(f"{label} is group/other writable: {path}")
    if not stat.S_IMODE(metadata.st_mode) & 0o400:
        raise ContractError(f"{label} is not owner-readable: {path}")
    if metadata.st_nlink != 1:
        raise ContractError(f"{label} must not be hard-linked: {path}")


def require_secure_directory(path: Path, owner: tuple[int, int], label: str) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError as error:
        raise ContractError(f"{label} is missing: {path}") from error
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise ContractError(f"{label} must be a real directory: {path}")
    if (metadata.st_uid, metadata.st_gid) != owner:
        raise ContractError(f"{label} has unsafe ownership: {path}")
    if stat.S_IMODE(metadata.st_mode) & 0o022:
        raise ContractError(f"{label} is group/other writable: {path}")


def read_secure_file(
    path: Path,
    owner: tuple[int, int],
    label: str,
    max_bytes: int,
) -> tuple[bytes, MetadataIdentity]:
    """Read one immutable config snapshot through a non-following descriptor."""

    require_secure_file(path, owner, label)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ContractError(f"{label} cannot be opened safely: {path}") from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise ContractError(f"{label} changed type while opening: {path}")
        if (before.st_uid, before.st_gid) != owner:
            raise ContractError(f"{label} changed ownership while opening: {path}")
        if stat.S_IMODE(before.st_mode) & 0o022 or before.st_nlink != 1:
            raise ContractError(f"{label} became writable or hard-linked: {path}")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(65536, max_bytes + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > max_bytes:
                raise ContractError(f"{label} exceeds the reviewed byte limit: {path}")
        after = os.fstat(descriptor)
        if metadata_identity(before) != metadata_identity(after):
            raise ContractError(f"{label} changed while it was being read: {path}")
        return b"".join(chunks), metadata_identity(before)
    finally:
        os.close(descriptor)


def decode_config(data: bytes, path: Path, label: str) -> str:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ContractError(f"{label} is not UTF-8: {path}") from error
    if "\x00" in text:
        raise ContractError(f"{label} contains a NUL byte: {path}")
    return text


class IncludeResolver:
    """Expand local server-scope includes using fail-closed filesystem rules."""

    MAX_INCLUDE_DEPTH = 32
    MAX_INCLUDED_FILES = 256
    MAX_INCLUDED_BYTES = 8 * 1024 * 1024

    def __init__(
        self,
        nginx_root: Path,
        owner: tuple[int, int],
        root_source: Path,
        sensitive_snippet: Path,
        legacy_snippet: Path,
    ) -> None:
        self.nginx_root = nginx_root
        self.owner = owner
        self.root_source = root_source.resolve(strict=True)
        self.special_paths = {
            sensitive_snippet.resolve(strict=True): ("sensitive", sensitive_snippet),
            legacy_snippet.resolve(strict=True): ("legacy", legacy_snippet),
        }
        self.included_files = 0
        self.included_bytes = 0
        self.checked_directories: set[Path] = set()
        self.file_snapshots: dict[Path, MetadataIdentity] = {}
        self.directory_snapshots: dict[Path, MetadataIdentity] = {}

    def expand_document(
        self, document: Sequence[Directive], source: Path
    ) -> tuple[EffectiveDirective, ...]:
        resolved_source = source.resolve(strict=True)
        return self._expand_sequence(
            document,
            source=resolved_source,
            stack=(resolved_source,),
            include_depth=0,
        )

    def _is_within_root(self, path: Path) -> bool:
        return path == self.nginx_root or self.nginx_root in path.parents

    def _secure_include_path(self, path: Path) -> Path:
        try:
            resolved = path.resolve(strict=True)
        except (OSError, RuntimeError) as error:
            raise ContractError(f"included Nginx file is unreadable: {path}") from error
        if not self._is_within_root(resolved):
            raise ContractError(f"included Nginx file escapes the reviewed root: {path}")

        parent = path.parent
        while True:
            if parent not in self.checked_directories:
                require_secure_directory(parent, self.owner, "included config directory")
                self.checked_directories.add(parent)
                self.directory_snapshots[parent] = metadata_identity(parent.lstat())
            if parent == self.nginx_root:
                break
            if parent == parent.parent or not self._is_within_root(parent):
                raise ContractError(f"included Nginx path escapes the reviewed root: {path}")
            parent = parent.parent
        require_secure_file(path, self.owner, "included Nginx file")
        return resolved

    def _include_matches(self, raw_path: str, source: Path) -> list[Path]:
        if "$" in raw_path or "\x00" in raw_path or "\\" in raw_path:
            raise ContractError(
                f"{source}: dynamic or escaped Nginx include path is not allowed"
            )
        candidate = Path(raw_path)
        if not candidate.is_absolute():
            candidate = self.nginx_root / candidate
        candidate = Path(os.path.abspath(candidate))
        if not self._is_within_root(candidate):
            raise ContractError(f"{source}: Nginx include escapes the reviewed root")
        matches: set[Path] = set()
        for match in glob.iglob(str(candidate)):
            matches.add(Path(match))
            if len(matches) > self.MAX_INCLUDED_FILES:
                raise ContractError("Nginx include glob exceeds the reviewed file limit")
        ordered_matches = sorted(matches)
        if not ordered_matches:
            raise ContractError(f"{source}: Nginx include matched no readable files: {raw_path}")
        return ordered_matches

    def _expand_include(
        self,
        directive: Directive,
        source: Path,
        stack: tuple[Path, ...],
        include_depth: int,
    ) -> tuple[EffectiveDirective, ...]:
        if len(directive.args) != 1:
            raise ContractError(
                f"{source}:{directive.line}: include must have exactly one local path"
            )
        raw_path = directive.args[0]
        expanded: list[EffectiveDirective] = []
        for matched in self._include_matches(raw_path, source):
            resolved = self._secure_include_path(matched)
            special = self.special_paths.get(resolved)
            if resolved in stack:
                chain = " -> ".join(str(path) for path in (*stack, resolved))
                raise ContractError(f"recursive Nginx include cycle: {chain}")
            if include_depth >= self.MAX_INCLUDE_DEPTH:
                raise ContractError("Nginx include nesting exceeds the reviewed limit")
            if self.included_files >= self.MAX_INCLUDED_FILES:
                raise ContractError("Nginx include file count exceeds the reviewed limit")
            remaining_bytes = self.MAX_INCLUDED_BYTES - self.included_bytes
            if remaining_bytes <= 0:
                raise ContractError("Nginx include bytes exceed the reviewed limit")
            data, observed_identity = read_secure_file(
                matched,
                self.owner,
                "included Nginx file",
                remaining_bytes,
            )
            previous_identity = self.file_snapshots.get(matched)
            if previous_identity is not None and previous_identity != observed_identity:
                raise ContractError(f"included Nginx file changed between reads: {matched}")
            self.file_snapshots[matched] = observed_identity
            self.included_files += 1
            self.included_bytes += len(data)
            text = decode_config(data, matched, "included Nginx file")
            document = parse(text, matched)

            if special is not None:
                special_kind, special_path = special
                validate_reviewed_snippet(special_kind, document, matched)
                requested = Path(raw_path)
                if not requested.is_absolute():
                    requested = self.nginx_root / requested
                requested = Path(os.path.abspath(requested))
                reviewed = (
                    not glob.has_magic(raw_path)
                    and requested == special_path
                    and source == self.root_source
                    and include_depth == 0
                )
                expanded.append(
                    EffectiveDirective(
                        "include",
                        (str(special_path),),
                        None,
                        directive.line,
                        source,
                        reviewed_include=reviewed,
                    )
                )
                expanded.extend(
                    self._expand_sequence(
                        document,
                        source=resolved,
                        stack=(*stack, resolved),
                        include_depth=include_depth + 1,
                        reviewed_origin=special_kind,
                    )
                )
                continue
            expanded.extend(
                self._expand_sequence(
                    document,
                    source=resolved,
                    stack=(*stack, resolved),
                    include_depth=include_depth + 1,
                )
            )
        return tuple(expanded)

    def revalidate_snapshots(self) -> None:
        """Ensure pathnames still identify the immutable objects we parsed."""

        for path, expected in self.file_snapshots.items():
            require_secure_file(path, self.owner, "included Nginx file")
            if metadata_identity(path.lstat()) != expected:
                raise ContractError(f"included Nginx file changed after validation: {path}")
        for path, expected in self.directory_snapshots.items():
            require_secure_directory(path, self.owner, "included config directory")
            if metadata_identity(path.lstat()) != expected:
                raise ContractError(
                    f"included config directory changed after validation: {path}"
                )

    def _expand_sequence(
        self,
        directives: Sequence[Directive],
        source: Path,
        stack: tuple[Path, ...],
        include_depth: int,
        reviewed_origin: str | None = None,
    ) -> tuple[EffectiveDirective, ...]:
        expanded: list[EffectiveDirective] = []
        for directive in directives:
            if directive.name.lower() == "include":
                expanded.extend(
                    self._expand_include(directive, source, stack, include_depth)
                )
                continue
            children = None
            if directive.children is not None:
                children = self._expand_sequence(
                    directive.children,
                    source=source,
                    stack=stack,
                    include_depth=include_depth,
                    reviewed_origin=reviewed_origin,
                )
            expanded.append(
                EffectiveDirective(
                    directive.name,
                    directive.args,
                    children,
                    directive.line,
                    source,
                    reviewed_origin=reviewed_origin,
                )
            )
        return tuple(expanded)


def is_tls_listener(node: Directive | EffectiveDirective) -> bool:
    listeners = [
        child
        for child in (node.children or ())
        if child.name.lower() == "listen"
    ]
    for listener in listeners:
        lowered = [argument.lower() for argument in listener.args]
        endpoint_443 = any(
            TLS_443_ENDPOINT_PATTERN.fullmatch(argument) for argument in lowered
        )
        if endpoint_443 and "ssl" in lowered:
            return True
    return False


def host_server_blocks(
    document: Sequence[Directive | EffectiveDirective], hostname: str
) -> list[Directive | EffectiveDirective]:
    blocks: list[Directive | EffectiveDirective] = []
    for node in document:
        if node.name.lower() != "server" or node.children is None:
            continue
        names = [
            argument.lower()
            for item in (node.children or ())
            if item.name.lower() == "server_name"
            for argument in item.args
        ]
        # Port 80 redirect blocks legitimately repeat the public names.  The
        # security contract selects exactly one TLS virtual host, not exactly
        # one server_name occurrence across all protocols.
        if hostname.lower() in names and is_tls_listener(node):
            blocks.append(node)
    return blocks


def location_path(
    node: Directive | EffectiveDirective,
) -> tuple[str, str] | None:
    if node.name.lower() != "location" or not node.args:
        return None
    if node.args[0] in ("=", "~", "~*", "^~"):
        if len(node.args) < 2:
            return node.args[0], ""
        return node.args[0], node.args[1]
    return "", node.args[0]


def is_sensitive_exact_uri(path: str) -> bool:
    return any(pattern.search(path) for pattern in SENSITIVE_EXACT_URI_PATTERNS)


def is_legacy_images_location(modifier: str, path: str) -> bool:
    lowered = path.lower().replace(r"\/", "/")
    if modifier in ("~", "~*"):
        return "/images" in lowered
    return lowered == "/images" or lowered.startswith("/images/")


ALLOWED_REGEX_PROFILES: dict[str, dict[tuple[str, str], str]] = {
    WWW_HOST: {
        ("~*", r"/(?:uploads|files)/.*\.php$"): "deny-404",
        ("~", r"\.php$"): "www-php",
        ("~*", r"\.m3u8$"): "root-try-files",
        ("~*", r"\.(?:ts|mp4|m4v|webm)$"): "root-try-files",
        (
            "~*",
            r"\.(?:jpg|jpeg|png|gif|webp|avif|ico|css|js|svg|woff|woff2)$",
        ): "root-try-files",
        ("~", r"/\."): "deny-all",
        ("~", r"^/health/[0-9]{1,5}$"): "health-204",
    },
    IMG_HOST: {
        (
            "~*",
            r"\.(?:jpg|jpeg|png|gif|webp|avif|ico|css|js|svg|woff|woff2)$",
        ): "root-try-files",
        ("~", r"\.php$"): "deny-404",
        ("~", r"/\."): "deny-all",
        ("~", r"^/health/[0-9]{1,5}$"): "health-204",
    },
}


UPSTREAM_OR_ALIAS_DIRECTIVES = {
    "alias",
    "proxy_pass",
    "fastcgi_pass",
    "uwsgi_pass",
    "scgi_pass",
    "grpc_pass",
}

PHP_EXECUTION_PARAMETER_CONTRACT: dict[str, tuple[str, ...]] = {
    "SCRIPT_FILENAME": ("$document_root$fastcgi_script_name",),
    "DOCUMENT_ROOT": ("$document_root",),
    "SCRIPT_NAME": ("$fastcgi_script_name",),
    "PATH_INFO": ("$path_info",),
}
FORBIDDEN_PHP_EXECUTION_PARAMETERS = {
    "PATH_TRANSLATED",
    "PHP_VALUE",
    "PHP_ADMIN_VALUE",
}


def nested_items(node: EffectiveDirective) -> list[EffectiveDirective]:
    return [node, *effective_descendants(node)]


def validate_php_execution_contract(
    hostname: str, location: EffectiveDirective
) -> None:
    """Require the deployed Debian FastCGI execution-target semantics.

    Includes are already expanded in textual order, so this sees both
    ``snippets/fastcgi-php.conf`` and its recursive ``fastcgi.conf`` include.
    Duplicate parameters are unsafe even when one copy is correct: FastCGI
    consumers can use the first or last value and a later include could change
    the PHP file that FPM executes.
    """

    expanded_body = [item for item in nested_items(location) if item is not location]
    parameters: dict[str, list[EffectiveDirective]] = {}
    for item in expanded_body:
        if item.name.lower() != "fastcgi_param" or not item.args:
            continue
        parameters.setdefault(item.args[0].upper(), []).append(item)

    for name, expected_value in PHP_EXECUTION_PARAMETER_CONTRACT.items():
        matches = parameters.get(name, [])
        if len(matches) != 1 or matches[0].args[1:] != expected_value:
            raise ContractError(
                f"{hostname} reviewed PHP execution target parameters drifted"
            )
    if any(parameters.get(name) for name in FORBIDDEN_PHP_EXECUTION_PARAMETERS):
        raise ContractError(
            f"{hostname} reviewed PHP execution target parameters drifted"
        )

    split_path = [
        item for item in expanded_body if item.name.lower() == "fastcgi_split_path_info"
    ]
    path_info_sets = [
        item
        for item in expanded_body
        if item.name.lower() == "set"
        and item.args
        and item.args[0] == "$path_info"
    ]
    indexes = [
        item for item in expanded_body if item.name.lower() == "fastcgi_index"
    ]
    try_files = [item for item in expanded_body if item.name.lower() == "try_files"]
    conditional_blocks = [
        item
        for item in expanded_body
        if item.children is not None and item.name.lower() in ("if", "limit_except")
    ]
    if (
        conditional_blocks
        or len(split_path) != 1
        or split_path[0].args != (r"^(.+?\.php)(/.*)$",)
        or len(path_info_sets) != 1
        or path_info_sets[0].args != ("$path_info", "$fastcgi_path_info")
        or len(indexes) != 1
        or indexes[0].args != ("index.php",)
        or len(try_files) != 1
        or try_files[0].args != ("$fastcgi_script_name", "=404")
    ):
        raise ContractError(f"{hostname} reviewed PHP preflight semantics drifted")


def validate_php_handler_contract(
    hostname: str, location: EffectiveDirective
) -> None:
    expanded_body = [
        item for item in nested_items(location) if item is not location
    ]
    passes = [item for item in expanded_body if item.name.lower() == "fastcgi_pass"]
    other_handlers = [
        item
        for item in expanded_body
        if item.name.lower() in UPSTREAM_OR_ALIAS_DIRECTIVES
        and item.name.lower() != "fastcgi_pass"
    ]
    if (
        other_handlers
        or len(passes) != 1
        or passes[0].args != ("unix:/var/run/php/php8.3-fpm.sock",)
    ):
        raise ContractError(f"{hostname} reviewed PHP handler drifted")
    validate_php_execution_contract(hostname, location)


def validate_allowed_regex_location(
    hostname: str,
    location: EffectiveDirective,
    modifier: str,
    pattern: str,
) -> None:
    profile = ALLOWED_REGEX_PROFILES[hostname].get((modifier, pattern))
    if profile is None:
        raise ContractError(
            f"{hostname} contains a regex location outside the reviewed allowlist"
        )

    body = list(location.children or ())
    body_ids = {id(item) for item in body}
    body_and_nested = nested_items(location)
    expanded_body = [item for item in body_and_nested if item is not location]
    forbidden_handlers = [
        item
        for item in expanded_body
        if item.name.lower() in UPSTREAM_OR_ALIAS_DIRECTIVES
    ]
    returns = [item for item in expanded_body if item.name.lower() == "return"]
    try_files = [item for item in expanded_body if item.name.lower() == "try_files"]
    denies = [item for item in expanded_body if item.name.lower() == "deny"]
    access_overrides = [
        item
        for item in expanded_body
        if item.name.lower() in ("allow", "satisfy")
    ]
    conditional_blocks = [
        item
        for item in expanded_body
        if item.children is not None and item.name.lower() in ("if", "limit_except")
    ]

    if profile == "root-try-files":
        if (
            forbidden_handlers
            or returns
            or conditional_blocks
            or len(try_files) != 1
            or id(try_files[0]) not in body_ids
        ):
            raise ContractError(f"{hostname} reviewed static regex handler drifted")
        if try_files[0].args != ("$uri", "=404"):
            raise ContractError(f"{hostname} reviewed static regex must fail closed")
        return

    if profile == "www-php":
        validate_php_handler_contract(hostname, location)
        return

    if profile in ("deny-404", "health-204"):
        expected_code = "404" if profile == "deny-404" else "204"
        if (
            forbidden_handlers
            or try_files
            or conditional_blocks
            or len(returns) != 1
            or id(returns[0]) not in body_ids
            or returns[0].args != (expected_code,)
        ):
            raise ContractError(f"{hostname} reviewed return-only regex handler drifted")
        return

    if profile == "deny-all":
        if (
            forbidden_handlers
            or try_files
            or returns
            or access_overrides
            or conditional_blocks
            or len(denies) != 1
            or id(denies[0]) not in body_ids
            or denies[0].args != ("all",)
        ):
            raise ContractError(f"{hostname} reviewed dotfile regex handler drifted")
        return

    raise ContractError(f"{hostname} has an unknown regex review profile")


def validate_server_block(
    effective_node: EffectiveDirective,
    hostname: str,
    site_root: Path,
    sensitive_include: str,
    legacy_include: str,
) -> None:
    if not is_tls_listener(effective_node):
        raise ContractError(f"{hostname} must have a direct 443 ssl listener")

    roots = effective_direct(effective_node, "root")
    all_roots = [
        item
        for item in [effective_node, *effective_descendants(effective_node)]
        if item.name.lower() == "root"
    ]
    expected_root = os.path.normpath(str(site_root))
    if len(roots) != 1 or len(all_roots) != 1 or len(roots[0].args) != 1:
        raise ContractError(
            f"{hostname} must have exactly one direct root directive and no nested override"
        )
    configured_root = roots[0].args[0]
    if "$" in configured_root or not os.path.isabs(configured_root):
        raise ContractError(f"{hostname} root must be a fixed absolute path")
    if os.path.normpath(configured_root) != expected_root:
        raise ContractError(f"{hostname} root is not the reviewed site root")

    includes = [effective_node, *effective_descendants(effective_node)]
    include_contract = (
        (sensitive_include, "sensitive-file"),
        (legacy_include, "legacy-images"),
    )
    direct_children = list(effective_node.children or ())
    include_indexes: dict[str, int] = {}
    for include_path, label in include_contract:
        matches = [
            item
            for item in includes
            if item.name.lower() == "include" and item.args == (include_path,)
        ]
        direct_matches = [
            item
            for item in effective_direct(effective_node, "include")
            if item.args == (include_path,)
        ]
        if (
            len(matches) != 1
            or len(direct_matches) != 1
            or not direct_matches[0].reviewed_include
        ):
            raise ContractError(
                f"{hostname} must explicitly include {label} exactly once as a direct server child"
            )
        include_indexes[include_path] = direct_children.index(direct_matches[0])

    if include_indexes[sensitive_include] >= include_indexes[legacy_include]:
        raise ContractError(f"{hostname} must include sensitive-file before legacy-images")
    location_indexes = [
        index
        for index, child in enumerate(direct_children)
        if child.name.lower() == "location" and child.reviewed_origin is None
    ]
    if location_indexes and max(include_indexes.values()) >= min(location_indexes):
        raise ContractError(f"{hostname} security includes must precede every location")

    forbidden_redirectors = [
        item
        for item in effective_descendants(effective_node)
        if item.name.lower() in ("rewrite", "error_page", "internal_redirect")
    ]
    if forbidden_redirectors:
        raise ContractError(
            f"{hostname} contains rewrite/error-page routing that can bypass denies"
        )

    direct_location_ids = {
        id(item) for item in direct_children if item.name.lower() == "location"
    }
    all_locations = [
        item
        for item in effective_descendants(effective_node)
        if item.name.lower() == "location"
    ]
    if any(id(item) not in direct_location_ids for item in all_locations):
        raise ContractError(
            f"{hostname} contains a nested location that can outrank server regex rules"
        )

    for item in all_locations:
        parsed_location = location_path(item)
        if parsed_location is None:
            continue
        modifier, path = parsed_location
        location_fastcgi_passes = [
            descendant
            for descendant in effective_descendants(item)
            if descendant.name.lower() == "fastcgi_pass"
        ]
        if location_fastcgi_passes and modifier not in ("~", "~*"):
            validate_php_handler_contract(hostname, item)
        if modifier == "" and path.startswith("@"):
            raise ContractError(f"{hostname} contains an unreviewed named location")
        # Any ^~ prefix suppresses all regex locations below it. Even a
        # seemingly harmless prefix can later contain an .env, key, backup or
        # source-control path, so none are compatible with the deny snippet.
        if modifier == "^~":
            raise ContractError(
                f"{hostname} has a ^~ location that bypasses sensitive regex rules"
            )
        # An exact location wins before regex selection. Mirror every URI
        # family denied by shuzijun-sensitive-files-deny.conf so a return,
        # alias or FastCGI handler cannot carve out a higher-priority bypass.
        if modifier == "=" and is_sensitive_exact_uri(path):
            raise ContractError(
                f"{hostname} has an exact location that bypasses sensitive regex rules"
            )
        if (
            item.reviewed_origin not in ("sensitive", "legacy")
            and is_legacy_images_location(modifier, path)
        ):
            raise ContractError(
                f"{hostname} contains an inline legacy /images location; use the reviewed snippet"
            )
        if (
            modifier in ("~", "~*")
            and item.reviewed_origin not in ("sensitive", "legacy")
        ):
            validate_allowed_regex_location(hostname, item, modifier, path)


def require_only_canonical_enabled_entry(
    enabled_directory: Path, enabled_entry: Path
) -> None:
    try:
        entries = sorted(enabled_directory.iterdir(), key=lambda path: path.name)
    except OSError as error:
        raise ContractError(f"cannot inspect sites-enabled directory: {enabled_directory}") from error
    if entries != [enabled_entry]:
        rendered = ", ".join(entry.name for entry in entries) or "none"
        raise ContractError(
            "sites-enabled must contain only the canonical reviewed entry "
            f"(found: {rendered})"
        )


def snapshot_canonical_enabled_symlink(
    enabled_entry: Path,
    site_config: Path,
    owner: tuple[int, int],
) -> tuple[MetadataIdentity, str]:
    try:
        metadata = enabled_entry.lstat()
    except FileNotFoundError as error:
        raise ContractError(
            f"canonical sites-enabled entry is missing: {enabled_entry}"
        ) from error
    if (metadata.st_uid, metadata.st_gid) != owner:
        raise ContractError("canonical sites-enabled entry has unsafe ownership")
    if not stat.S_ISLNK(metadata.st_mode):
        raise ContractError(
            "canonical sites-enabled entry must be a symlink to sites-available"
        )
    if metadata.st_nlink != 1:
        raise ContractError("canonical sites-enabled symlink must not be hard-linked")
    try:
        raw_target = os.readlink(enabled_entry)
    except OSError as error:
        raise ContractError("cannot read the canonical sites-enabled symlink") from error
    lexical_target = Path(raw_target)
    if not lexical_target.is_absolute():
        lexical_target = enabled_entry.parent / lexical_target
    lexical_target = Path(os.path.abspath(lexical_target))
    if lexical_target != site_config:
        raise ContractError(
            "sites-enabled entry does not directly target the canonical site config"
        )
    try:
        if enabled_entry.resolve(strict=True) != site_config.resolve(strict=True):
            raise ContractError("sites-enabled entry does not activate the canonical site config")
    except OSError as error:
        raise ContractError("cannot resolve the canonical sites-enabled entry") from error
    return metadata_identity(metadata), raw_target


def validate(args: argparse.Namespace) -> None:
    site_root = args.site_root
    site_config = args.site_config
    enabled_entry = args.enabled_entry
    sensitive_snippet = args.sensitive_snippet
    legacy_snippet = args.legacy_snippet
    config_owner = parse_identity(args.config_owner)
    site_owner = parse_identity(args.site_root_owner)

    for path, label in (
        (site_root, "site root"),
        (site_config, "canonical site config"),
        (enabled_entry, "canonical sites-enabled entry"),
        (sensitive_snippet, "sensitive-file snippet"),
        (legacy_snippet, "legacy-images snippet"),
    ):
        if not path.is_absolute():
            raise ContractError(f"{label} path must be absolute")
    try:
        if site_root.resolve(strict=True) != site_root:
            raise ContractError("site root path must not traverse a symlink")
    except OSError as error:
        raise ContractError(f"cannot resolve site root: {site_root}") from error

    require_secure_directory(site_root, site_owner, "site root")
    require_secure_file(site_config, config_owner, "canonical site config")
    require_secure_file(sensitive_snippet, config_owner, "sensitive-file snippet")
    require_secure_file(legacy_snippet, config_owner, "legacy-images snippet")
    require_secure_directory(enabled_entry.parent, config_owner, "sites-enabled directory")
    require_secure_directory(site_config.parent, config_owner, "sites-available directory")
    require_secure_directory(sensitive_snippet.parent, config_owner, "snippet directory")
    if legacy_snippet.parent != sensitive_snippet.parent:
        require_secure_directory(
            legacy_snippet.parent, config_owner, "legacy snippet directory"
        )
    nginx_root = Path(
        os.path.commonpath(
            (
                site_config.parent,
                enabled_entry.parent,
                sensitive_snippet.parent,
                legacy_snippet.parent,
            )
        )
    ).resolve(strict=True)
    if nginx_root == Path(nginx_root.anchor):
        raise ContractError("reviewed Nginx include root is too broad")
    require_secure_directory(nginx_root, config_owner, "reviewed Nginx include root")

    enabled_snapshot = snapshot_canonical_enabled_symlink(
        enabled_entry, site_config, config_owner
    )
    require_only_canonical_enabled_entry(enabled_entry.parent, enabled_entry)

    if os.path.lexists(site_root / "images"):
        raise ContractError("legacy document-root images entry still exists")

    site_config_data, site_config_snapshot = read_secure_file(
        site_config,
        config_owner,
        "canonical site config",
        IncludeResolver.MAX_INCLUDED_BYTES,
    )
    canonical_document = parse(
        decode_config(site_config_data, site_config, "canonical site config"),
        site_config,
    )

    include_resolver = IncludeResolver(
        nginx_root,
        config_owner,
        site_config,
        sensitive_snippet,
        legacy_snippet,
    )
    effective_document = include_resolver.expand_document(
        canonical_document, site_config
    )

    selected: dict[str, EffectiveDirective] = {}
    for hostname in (WWW_HOST, IMG_HOST):
        matches = host_server_blocks(effective_document, hostname)
        if len(matches) != 1:
            raise ContractError(
                f"{hostname} must appear in exactly one enabled TLS server block "
                f"(found {len(matches)})"
            )
        node = matches[0]
        if not isinstance(node, EffectiveDirective):
            raise ContractError(f"{hostname} was not expanded from canonical config")
        selected[hostname] = node

    if selected[WWW_HOST] is selected[IMG_HOST]:
        raise ContractError("www and img must use distinct TLS server blocks")
    sensitive_include = os.path.normpath(str(sensitive_snippet))
    legacy_include = os.path.normpath(str(legacy_snippet))
    for hostname, node in selected.items():
        validate_server_block(
            node,
            hostname,
            site_root,
            sensitive_include,
            legacy_include,
        )

    # Re-check every pathname after semantic validation.  Without this final
    # comparison an atomic rename could make nginx consume a different file
    # from the immutable descriptor snapshot that the checker parsed.
    include_resolver.revalidate_snapshots()
    require_secure_file(site_config, config_owner, "canonical site config")
    if metadata_identity(site_config.lstat()) != site_config_snapshot:
        raise ContractError("canonical site config changed after validation")
    require_only_canonical_enabled_entry(enabled_entry.parent, enabled_entry)
    if snapshot_canonical_enabled_symlink(
        enabled_entry, site_config, config_owner
    ) != enabled_snapshot:
        raise ContractError("canonical sites-enabled symlink changed after validation")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--site-root", type=Path, required=True)
    parser.add_argument("--site-config", type=Path, required=True)
    parser.add_argument("--enabled-entry", type=Path, required=True)
    parser.add_argument("--sensitive-snippet", type=Path, required=True)
    parser.add_argument("--legacy-snippet", type=Path, required=True)
    parser.add_argument("--config-owner", default="root:root")
    parser.add_argument("--site-root-owner", default="root:www-data")
    return parser


def main() -> int:
    try:
        validate(build_parser().parse_args())
    except ContractError as error:
        print(f"nginx-server-block-contract: {error}", file=sys.stderr)
        return 1
    print("nginx-server-block-contract: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
