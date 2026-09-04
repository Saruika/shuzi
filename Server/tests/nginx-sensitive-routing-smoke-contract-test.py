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
if [[ "$url" == *rest_route* || "$url" == *'/wp-json/shuzijun/v1/'* ]]; then
  status=401
  reason=Unauthorized
  code=fan_session_required
  if [[ "$url" == *rest_route* && "${FAKE_CURL_NODE_ROLE:-authority}" == standby ]]; then
    status=503
    reason='Service Unavailable'
    code=yishu_account_authority_unavailable
  fi
  {
    printf 'HTTP/1.1 %s %s\r\n' "$status" "$reason"
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
    printf '{"code":"%s"}' "$code" >"$output"
  fi
  printf '%s' "$status"
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
    node_role: str,
    resolve: str | None,
    mode: str = "valid",
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["PATH"] = f"{fake_bin}:{env['PATH']}"
    env["FAKE_CURL_MODE"] = mode
    env["FAKE_CURL_NODE_ROLE"] = node_role
    if resolve is None:
        env.pop("YISHU_SMOKE_RESOLVE", None)
    else:
        env["YISHU_SMOKE_RESOLVE"] = resolve
    return subprocess.run(
        ["bash", str(SMOKE), base_url, role, node_role],
        capture_output=True,
        text=True,
        env=env,
    )


def main() -> None:
    smoke_source = SMOKE.read_text(encoding="utf-8")
    for module in (
        "class-shuzijun-app-content-api.php",
        "trait-shuzijun-app-collaboration.php",
        "trait-shuzijun-app-fan-endpoints.php",
        "trait-shuzijun-app-fan-identity.php",
        "trait-shuzijun-app-content-delivery.php",
    ):
        assert (
            f'assert_status 404 "/wp-content/mu-plugins/vendor/'
            f'shuzijun/app-content/{module}"'
        ) in smoke_source

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
            "authority",
            "www.shuzijun.com.cn:443:127.0.0.1",
        )
        assert www.returncode == 0, www.stderr
        assert "role=www" in www.stdout
        assert "node-role=authority" in www.stdout

        standby = invoke(
            fake_bin,
            "https://www.shuzijun.com.cn",
            "www",
            "standby",
            "www.shuzijun.com.cn:443:127.0.0.1",
        )
        assert standby.returncode == 0, standby.stderr
        assert "node-role=standby" in standby.stdout

        img = invoke(
            fake_bin,
            "https://img.shuzijun.com.cn:8443",
            "img",
            "standby",
            "img.shuzijun.com.cn:8443:127.0.0.1",
        )
        assert img.returncode == 0, img.stderr
        assert "role=img" in img.stdout

        for base_url, role, node_role, resolve, expected in (
            (
                "https://www.shuzijun.com.cn",
                "www",
                "authority",
                None,
                "loopback resolve must exactly match",
            ),
            (
                "https://www.shuzijun.com.cn",
                "static",
                "authority",
                "www.shuzijun.com.cn:443:127.0.0.1",
                "role must be www or img",
            ),
            (
                "https://img.shuzijun.com.cn",
                "www",
                "standby",
                "img.shuzijun.com.cn:443:127.0.0.1",
                "base origin does not match role",
            ),
            (
                "https://www.shuzijun.com.cn:8443",
                "www",
                "authority",
                "www.shuzijun.com.cn:443:127.0.0.1",
                "loopback resolve must exactly match",
            ),
            (
                "https://www.shuzijun.com.cn",
                "www",
                "primary",
                "www.shuzijun.com.cn:443:127.0.0.1",
                "node role must be authority or standby",
            ),
        ):
            rejected = invoke(fake_bin, base_url, role, node_role, resolve)
            assert rejected.returncode == 2, rejected.stderr
            assert expected in rejected.stderr

        bad_json = invoke(
            fake_bin,
            "https://www.shuzijun.com.cn",
            "www",
            "authority",
            "www.shuzijun.com.cn:443:127.0.0.1",
            "bad-json",
        )
        assert bad_json.returncode != 0
        assert "protected JSON error code is unexpected" in bad_json.stderr

        missing_header = invoke(
            fake_bin,
            "https://www.shuzijun.com.cn",
            "www",
            "authority",
            "www.shuzijun.com.cn:443:127.0.0.1",
            "missing-header",
        )
        assert missing_header.returncode != 0
        assert "protected Referrer-Policy header is missing or unsafe" in missing_header.stderr

    print("nginx-sensitive-routing-smoke-contract-test: passed")


if __name__ == "__main__":
    main()
