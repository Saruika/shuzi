"""Execute the deployer's actual framed PHP evaluator; never deploy a bundle."""

import hashlib
from pathlib import Path
import re
import shutil
import subprocess


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    deployer = (root / "operations/deploy-app-content-release").read_text(encoding="utf-8")
    php = shutil.which("php")
    if php is None:
        raise RuntimeError("PHP is required for the executable release probe")
    php_start = deployer.index("        $payload = stream_get_contents(STDIN);")
    php_end = deployer.index("    ' \"$COLLABORATION_FUSE_PROBE_SENTINEL\"", php_start)
    evaluator = deployer[php_start:php_end]
    modules = re.search(r"readonly -a PLUGIN_MODULE_RELATIVES=\(\n(.*?)\n\)", deployer, re.S)
    assert modules is not None
    paths = [root / line.strip() for line in modules[1].splitlines()]
    assert len(paths) == 11 and all(path.is_file() for path in paths)
    sources = [path.read_bytes() for path in [*paths, root / "shuzijun-app-content.php"]]
    sentinel = "shuzijun-collaboration-fuse-probe-complete-v1"
    command_prefix = [
        php, "-n", "-d", "display_errors=0", "-d", "log_errors=0",
        "-d", "allow_url_fopen=0", "-d", "open_basedir=/nonexistent",
        "-d", "disable_functions=exec,passthru,shell_exec,system,proc_open,popen,mail,"
        "fsockopen,pfsockopen,stream_socket_client,stream_socket_server,curl_exec",
        "-r", evaluator, sentinel, "modular",
    ]
    cases = 0

    def expect(label: str, candidate: list[bytes], exit_code: int, payload: bytes | None = None) -> None:
        nonlocal cases
        command = command_prefix + [
            ",".join(str(len(source)) for source in candidate),
            ",".join(hashlib.sha256(source).hexdigest() for source in candidate),
        ]
        result = subprocess.run(
            command, input=b"".join(candidate) if payload is None else payload,
            capture_output=True, timeout=20, check=False,
        )
        expected_stdout = (sentinel + "\n").encode("ascii") if exit_code == 0 else b""
        assert result.returncode == exit_code and result.stdout == expected_stdout, (
            f"{label}: expected exit {exit_code}, got {result.returncode}; "
            f"stdout bytes={len(result.stdout)}, stderr bytes={len(result.stderr)}"
        )
        cases += 1

    payload = b"".join(sources)
    expect("reviewed graph and hard-off fuse", sources, 0)
    expect("changed payload hash", sources, 25, payload[:-1] + b"X")
    expect("truncated framing", sources, 26, payload[:-1])
    expect("trailing unframed byte", sources, 26, payload + b"X")
    expect("missing data source", sources[:9] + sources[10:], 26)
    reordered = list(sources)
    reordered[0], reordered[1] = reordered[1], reordered[0]
    expect("reordered trait declarations", reordered, 27)
    reordered_loaders = list(sources)
    first_loader = b"require_once __DIR__ . '/class-shuzijun-collaboration-private-payload.php';"
    last_loader = b"require_once __DIR__ . '/trait-shuzijun-app-game-leaderboard.php';"
    assert sources[10].count(first_loader) == sources[10].count(last_loader) == 1
    reordered_loaders[10] = sources[10].replace(first_loader, b"__PROBE_LOADER_SWAP__").replace(
        last_loader, first_loader
    ).replace(b"__PROBE_LOADER_SWAP__", last_loader)
    expect("reordered core loaders", reordered_loaders, 27)
    for operation in (b"require", b"require_once", b"include", b"include_once"):
        unknown_loader = list(sources)
        unknown_loader[10] += b"\n" + operation + b" '/nonexistent/unreviewed.php';\n"
        expect("unknown " + operation.decode("ascii"), unknown_loader, 27)
    changed_rules = list(sources)
    changed_rules[9] += b"\n"
    expect("JSON not bound to rules class hash", changed_rules, 28)
    malformed_rules = list(sources)
    malformed_rules[9] = b'{"version":"life-v1"}'
    original_rules_hash = hashlib.sha256(sources[9]).hexdigest().encode("ascii")
    malformed_hash = hashlib.sha256(malformed_rules[9]).hexdigest().encode("ascii")
    assert sources[8].count(original_rules_hash) == 1
    malformed_rules[8] = sources[8].replace(original_rules_hash, malformed_hash)
    expect("JSON schema invalid despite matching byte hash", malformed_rules, 28)
    enabled_fuse = list(sources)
    fuse = b"COLLABORATION_PHASE1_RELEASE_FUSE = false"
    assert sources[10].count(fuse) == 1
    enabled_fuse[10] = sources[10].replace(fuse, b"COLLABORATION_PHASE1_RELEASE_FUSE = true")
    expect("collaboration release fuse cannot be enabled", enabled_fuse, 22)
    print(f"collaboration-release-probe: {cases} cases passed; exact twelve-source graph, JSON binding, hard-off fuse, hashes and framing")


if __name__ == "__main__":
    main()
