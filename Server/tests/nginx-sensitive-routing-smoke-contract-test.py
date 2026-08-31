import os
import subprocess
import tempfile
from pathlib import Path


SMOKE = Path("Server/tests/nginx-sensitive-routing-smoke.sh").resolve()


FAKE_CURL = r"""#!/usr/bin/env bash
set -euo pipefail
headers=/dev/null
output=/dev/null
url=
while (( $# )); do
  case "$1" in
    --dump-header)
      headers=$2
      shift 2
      ;;
    --output)
      output=$2
      shift 2
      ;;
    --write-out|--resolve|--connect-timeout|--max-time|--max-redirs|--proto)
      shift 2
      ;;
    https://*)
      url=$1
      shift
      ;;
    *)
      shift
      ;;
  esac
done
if [[ "$url" == *rest_route* ]]; then
  {
    printf 'HTTP/1.1 401 Unauthorized\r\n'
    printf 'Content-Type: application/json; charset=UTF-8\r\n'
    printf 'X-Content-Type-Options: nosniff\r\n'
    printf 'X-Frame-Options: DENY\r\n'
    if [[ "${FAKE_CURL_MODE:-valid}" != missing-header ]]; then
      printf 'Referrer-Policy: no-referrer\r\n'
    fi
    printf 'X-Robots-Tag: noindex, nofollow\r\n'
    printf 'Cache-Control: private, no-store, max-age=0\r\n'
    printf 'Pragma: no-cache\r\n'
    printf 'Vary: Authorization, X-Yishu-Install-ID\r\n'
    printf '\r\n'
  } >"$headers"
  if [[ "${FAKE_CURL_MODE:-valid}" == bad-json ]]; then
    printf '%s' '{"code":"wrong_error"}' >"$output"
  else
    printf '%s' '{"code":"fan_session_required"}' >"$output"
  fi
  printf '401'
else
  : >"$headers"
  if [[ "$output" != /dev/null ]]; then : >"$output"; fi
  printf '404'
fi
"""


def invoke(
    fake_bin: Path,
    base_url: str,
    role: str,
    resolve: str | None,
    mode: str = "valid",
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["PATH"] = f"{fake_bin}:{env['PATH']}"
    env["FAKE_CURL_MODE"] = mode
    if resolve is None:
        env.pop("YISHU_SMOKE_RESOLVE", None)
    else:
        env["YISHU_SMOKE_RESOLVE"] = resolve
    return subprocess.run(
        ["bash", str(SMOKE), base_url, role],
        capture_output=True,
        text=True,
        env=env,
    )


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="yishu-nginx-smoke-") as temp_dir:
        fake_bin = Path(temp_dir) / "bin"
        fake_bin.mkdir()
        curl = fake_bin / "curl"
        curl.write_text(FAKE_CURL, encoding="utf-8")
        curl.chmod(0o755)

        www = invoke(
            fake_bin,
            "https://www.shuzijun.com.cn",
            "www",
            "www.shuzijun.com.cn:443:127.0.0.1",
        )
        assert www.returncode == 0, www.stderr
        assert "role=www" in www.stdout

        img = invoke(
            fake_bin,
            "https://img.shuzijun.com.cn:8443",
            "img",
            "img.shuzijun.com.cn:8443:127.0.0.1",
        )
        assert img.returncode == 0, img.stderr
        assert "role=img" in img.stdout

        for base_url, role, resolve, expected in (
            (
                "https://www.shuzijun.com.cn",
                "www",
                None,
                "loopback resolve must exactly match",
            ),
            (
                "https://www.shuzijun.com.cn",
                "static",
                "www.shuzijun.com.cn:443:127.0.0.1",
                "role must be www or img",
            ),
            (
                "https://img.shuzijun.com.cn",
                "www",
                "img.shuzijun.com.cn:443:127.0.0.1",
                "base origin does not match role",
            ),
            (
                "https://www.shuzijun.com.cn:8443",
                "www",
                "www.shuzijun.com.cn:443:127.0.0.1",
                "loopback resolve must exactly match",
            ),
        ):
            rejected = invoke(fake_bin, base_url, role, resolve)
            assert rejected.returncode == 2, rejected.stderr
            assert expected in rejected.stderr

        bad_json = invoke(
            fake_bin,
            "https://www.shuzijun.com.cn",
            "www",
            "www.shuzijun.com.cn:443:127.0.0.1",
            "bad-json",
        )
        assert bad_json.returncode != 0
        assert "401 JSON error code is unexpected" in bad_json.stderr

        missing_header = invoke(
            fake_bin,
            "https://www.shuzijun.com.cn",
            "www",
            "www.shuzijun.com.cn:443:127.0.0.1",
            "missing-header",
        )
        assert missing_header.returncode != 0
        assert "401 Referrer-Policy header is missing or unsafe" in missing_header.stderr

    print("nginx-sensitive-routing-smoke-contract-test: passed")


if __name__ == "__main__":
    main()
