#!/usr/bin/env python3
"""Validate the active Shuzijun Nginx virtual-host security contract.

This checker intentionally performs no network requests.  It parses the
enabled Nginx source directly so comments, quoted strings and nested blocks
cannot make a textual grep appear to satisfy the contract.
"""

from __future__ import annotations

import argparse
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


def tokenize(text: str, source: Path) -> list[Token]:
    """Tokenize enough of the Nginx grammar to locate directives reliably.

    A structural brace may be adjacent to a directive name.  Braces used by a
    regular-expression quantifier or a ${variable} remain part of that token.
    Comments are recognized only outside quoted strings.
    """

    tokens: list[Token] = []
    index = 0
    line = 1
    length = len(text)

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
            tokens.append(Token(char, line, True))
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
                    value.append(escaped)
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
            tokens.append(Token("".join(value), token_line))
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
                value.extend((char, text[index + 1]))
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
            if char == "{" and value:
                quantifier = re.match(r"\{[0-9]+(?:,[0-9]*)?\}", text[index:])
                if quantifier:
                    value.append(quantifier.group(0))
                    index += len(quantifier.group(0))
                    continue
            if char in "{}":
                break
            value.append(char)
            index += 1
        if not value:
            raise ContractError(f"{source}:{line}: cannot tokenize {text[index:index + 8]!r}")
        tokens.append(Token("".join(value), token_line))

    return tokens


def parse(text: str, source: Path) -> tuple[Directive, ...]:
    tokens = tokenize(text, source)
    position = 0

    def parse_scope(expect_close: bool) -> tuple[Directive, ...]:
        nonlocal position
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
                children = parse_scope(True)
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


def is_tls_listener(node: Directive) -> bool:
    for listener in direct(node, "listen"):
        lowered = [argument.lower() for argument in listener.args]
        endpoint_443 = any(
            TLS_443_ENDPOINT_PATTERN.fullmatch(argument) for argument in lowered
        )
        if endpoint_443 and "ssl" in lowered:
            return True
    return False


def host_server_blocks(document: Sequence[Directive], hostname: str) -> list[Directive]:
    blocks: list[Directive] = []
    for node in document:
        if node.name.lower() != "server" or node.children is None:
            continue
        names = [argument.lower() for item in direct(node, "server_name") for argument in item.args]
        if hostname.lower() in names:
            blocks.append(node)
    return blocks


def location_path(node: Directive) -> tuple[str, str] | None:
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


def validate_server_block(
    node: Directive,
    hostname: str,
    site_root: Path,
    sensitive_include: str,
    legacy_include: str,
) -> None:
    if not is_tls_listener(node):
        raise ContractError(f"{hostname} must have a direct 443 ssl listener")

    roots = direct(node, "root")
    expected_root = os.path.normpath(str(site_root))
    if len(roots) != 1 or len(roots[0].args) != 1:
        raise ContractError(f"{hostname} must have exactly one direct root directive")
    configured_root = roots[0].args[0]
    if "$" in configured_root or not os.path.isabs(configured_root):
        raise ContractError(f"{hostname} root must be a fixed absolute path")
    if os.path.normpath(configured_root) != expected_root:
        raise ContractError(f"{hostname} root is not the reviewed site root")

    includes = [node, *descendants(node)]
    include_contract = (
        (sensitive_include, "sensitive-file"),
        (legacy_include, "legacy-images"),
    )
    direct_children = list(node.children or ())
    include_indexes: dict[str, int] = {}
    for include_path, label in include_contract:
        matches = [
            item
            for item in includes
            if item.name.lower() == "include" and item.args == (include_path,)
        ]
        direct_matches = [item for item in direct(node, "include") if item.args == (include_path,)]
        if len(matches) != 1 or len(direct_matches) != 1:
            raise ContractError(
                f"{hostname} must include {label} exactly once as a direct server child"
            )
        include_indexes[include_path] = direct_children.index(direct_matches[0])

    if include_indexes[sensitive_include] >= include_indexes[legacy_include]:
        raise ContractError(f"{hostname} must include sensitive-file before legacy-images")
    location_indexes = [
        index
        for index, child in enumerate(direct_children)
        if child.name.lower() == "location"
    ]
    if location_indexes and max(include_indexes.values()) >= min(location_indexes):
        raise ContractError(f"{hostname} security includes must precede every location")

    for item in descendants(node):
        parsed_location = location_path(item)
        if parsed_location is None:
            continue
        modifier, path = parsed_location
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
        if is_legacy_images_location(modifier, path):
            raise ContractError(
                f"{hostname} contains an inline legacy /images location; use the reviewed snippet"
            )


def load_enabled_documents(enabled_directory: Path) -> dict[Path, tuple[Directive, ...]]:
    documents: dict[Path, tuple[Directive, ...]] = {}
    try:
        entries = sorted(enabled_directory.iterdir(), key=lambda path: path.name)
    except OSError as error:
        raise ContractError(f"cannot inspect sites-enabled directory: {enabled_directory}") from error
    for entry in entries:
        try:
            if not entry.is_file():
                continue
            text = entry.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            raise ContractError(f"cannot read enabled Nginx entry: {entry}") from error
        documents[entry] = parse(text, entry)
    return documents


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

    try:
        enabled_metadata = enabled_entry.lstat()
    except FileNotFoundError as error:
        raise ContractError(f"canonical sites-enabled entry is missing: {enabled_entry}") from error
    if (enabled_metadata.st_uid, enabled_metadata.st_gid) != config_owner:
        raise ContractError("canonical sites-enabled entry has unsafe ownership")
    if not stat.S_ISLNK(enabled_metadata.st_mode):
        raise ContractError(
            "canonical sites-enabled entry must be a symlink to sites-available"
        )
    try:
        if enabled_entry.resolve(strict=True) != site_config.resolve(strict=True):
            raise ContractError("sites-enabled entry does not activate the canonical site config")
    except OSError as error:
        raise ContractError("cannot resolve the canonical sites-enabled entry") from error

    if os.path.lexists(site_root / "images"):
        raise ContractError("legacy document-root images entry still exists")

    documents = load_enabled_documents(enabled_entry.parent)
    canonical_document = documents.get(enabled_entry)
    if canonical_document is None:
        raise ContractError("canonical sites-enabled entry is not an enabled regular config")

    selected: dict[str, Directive] = {}
    for hostname in (WWW_HOST, IMG_HOST):
        matches: list[tuple[Path, Directive]] = []
        for source, document in documents.items():
            matches.extend((source, node) for node in host_server_blocks(document, hostname))
        if len(matches) != 1:
            raise ContractError(
                f"{hostname} must appear in exactly one enabled server block (found {len(matches)})"
            )
        source, node = matches[0]
        if source != enabled_entry:
            raise ContractError(f"{hostname} is not provided by the canonical enabled entry")
        selected[hostname] = node

    if selected[WWW_HOST] is selected[IMG_HOST]:
        raise ContractError("www and img must use distinct TLS server blocks")
    sensitive_include = os.path.normpath(str(sensitive_snippet))
    legacy_include = os.path.normpath(str(legacy_snippet))
    for hostname, node in selected.items():
        validate_server_block(
            node, hostname, site_root, sensitive_include, legacy_include
        )


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
