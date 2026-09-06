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
    assert len(paths) == 7 and all(path.is_file() for path in paths)
    sources = [path.read_bytes() for path in [*paths, root / "shuzijun-app-content.php"]]
    sizes = ",".join(str(len(source)) for source in sources)
    hashes = ",".join(hashlib.sha256(source).hexdigest() for source in sources)
    payload = b"".join(sources)
    sentinel = "shuzijun-collaboration-fuse-probe-complete-v1"
    command = [
        php, "-n", "-d", "display_errors=0", "-d", "log_errors=0",
        "-d", "allow_url_fopen=0", "-d", "open_basedir=/nonexistent",
        "-d", "disable_functions=exec,passthru,shell_exec,system,proc_open,popen,mail,"
        "fsockopen,pfsockopen,stream_socket_client,stream_socket_server,curl_exec",
        "-r", evaluator, sentinel, "modular", sizes, hashes,
    ]
    valid = subprocess.run(command, input=payload, capture_output=True, timeout=20, check=False)
    assert valid.returncode == 0 and valid.stdout == (sentinel + "\n").encode("ascii")
    damaged = subprocess.run(command, input=payload[:-1] + b"X", capture_output=True, timeout=20, check=False)
    assert damaged.returncode == 25 and damaged.stdout == b""
    truncated = subprocess.run(command, input=payload[:-1], capture_output=True, timeout=20, check=False)
    assert truncated.returncode == 26 and truncated.stdout == b""
    print("collaboration-release-probe: exact eight-source graph, hard-off fuse, hash and framing passed")


if __name__ == "__main__":
    main()
