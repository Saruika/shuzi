#!/usr/bin/env bash
set -euo pipefail

base_url=${1:-https://www.shuzijun.com.cn}
origin_role=${2:-www}
node_role=${3:-}
resolve_target=${YISHU_SMOKE_RESOLVE:-}

if [[ "$origin_role" == www ]]; then
    expected_host=www.shuzijun.com.cn
elif [[ "$origin_role" == img ]]; then
    expected_host=img.shuzijun.com.cn
else
    printf 'nginx-sensitive-routing-smoke: role must be www or img\n' >&2
    exit 2
fi
if [[ "$node_role" != authority && "$node_role" != standby ]]; then
    printf 'nginx-sensitive-routing-smoke: node role must be authority or standby\n' >&2
    exit 2
fi
if [[ ! "$base_url" =~ ^https://([A-Za-z0-9.-]+)(:([1-9][0-9]{0,4}))?$ ]]; then
    printf 'nginx-sensitive-routing-smoke: base URL must be an HTTPS origin\n' >&2
    exit 2
fi
base_host=${BASH_REMATCH[1]}
base_port=${BASH_REMATCH[3]:-443}
if [[ "$base_host" != "$expected_host" ]] || (( 10#$base_port > 65535 )); then
    printf 'nginx-sensitive-routing-smoke: base origin does not match role\n' >&2
    exit 2
fi
expected_resolve="$base_host:$base_port:127.0.0.1"
if [[ "$resolve_target" != "$expected_resolve" ]]; then
    printf 'nginx-sensitive-routing-smoke: loopback resolve must exactly match base host and port\n' >&2
    exit 2
fi

curl_args=(
    --quiet
    --silent
    --show-error
    --path-as-is
    --proto '=https'
    --tlsv1.2
    --connect-timeout 5
    --max-time 15
    --max-redirs 0
    --noproxy '*'
    --resolve "$resolve_target"
)
response_dir=$(mktemp -d "${TMPDIR:-/tmp}/yishu-nginx-routing.XXXXXX")
trap 'rm -rf "$response_dir"' EXIT
request_number=0

assert_status() {
    local expected=$1
    local request_path=$2
    local actual

    actual=$(curl "${curl_args[@]}" --output /dev/null --write-out '%{http_code}' \
        "$base_url$request_path")
    if [[ "$actual" != "$expected" ]]; then
        printf 'nginx-sensitive-routing-smoke: expected %s, received %s for %s\n' \
            "$expected" "$actual" "$request_path" >&2
        return 1
    fi
}

header_values() {
    local header_file=$1
    local requested_name=$2
    awk -v requested_name="$requested_name" '
        BEGIN { requested_name = tolower(requested_name) }
        {
            line = $0
            sub(/\r$/, "", line)
            separator = index(line, ":")
            if (!separator) { next }
            name = tolower(substr(line, 1, separator - 1))
            if (name != requested_name) { next }
            value = substr(line, separator + 1)
            sub(/^[[:space:]]+/, "", value)
            print tolower(value)
        }
    ' "$header_file"
}

assert_header_pattern() {
    local header_file=$1
    local label=$2
    local pattern=$3
    if ! grep -Eiq -- "$pattern" "$header_file"; then
        printf 'nginx-sensitive-routing-smoke: protected %s header is missing or unsafe\n' \
            "$label" >&2
        return 1
    fi
}

assert_secure_api_error() {
    local expected_status=$1
    local expected_code=$2
    local request_path=$3
    local headers body status cache_control vary
    request_number=$((request_number + 1))
    headers="$response_dir/headers-$request_number"
    body="$response_dir/body-$request_number"
    status=$(curl "${curl_args[@]}" --dump-header "$headers" --output "$body" \
        --write-out '%{http_code}' "$base_url$request_path")
    if [[ "$status" != "$expected_status" ]]; then
        printf 'nginx-sensitive-routing-smoke: expected %s, received %s for %s\n' \
            "$expected_status" "$status" "$request_path" >&2
        return 1
    fi

    assert_header_pattern "$headers" Content-Type \
        '^content-type:[[:space:]]*application/json([;[:space:]]|$)'
    assert_header_pattern "$headers" X-Content-Type-Options \
        '^x-content-type-options:[[:space:]]*nosniff[[:space:]]*$'
    assert_header_pattern "$headers" X-Frame-Options \
        '^x-frame-options:[[:space:]]*deny[[:space:]]*$'
    assert_header_pattern "$headers" Referrer-Policy \
        '^referrer-policy:[[:space:]]*no-referrer[[:space:]]*$'
    assert_header_pattern "$headers" X-Robots-Tag \
        '^x-robots-tag:[[:space:]]*noindex,[[:space:]]*nofollow[[:space:]]*$'
    assert_header_pattern "$headers" Pragma \
        '^pragma:[[:space:]]*no-cache[[:space:]]*$'

    cache_control=$(header_values "$headers" cache-control | paste -sd, -)
    vary=$(header_values "$headers" vary | paste -sd, -)
    for required_cache_token in private no-store max-age=0; do
        if [[ ",${cache_control// /}," != *",$required_cache_token,"* ]]; then
            printf 'nginx-sensitive-routing-smoke: protected Cache-Control is incomplete\n' >&2
            return 1
        fi
    done
    for required_vary_token in authorization x-yishu-install-id; do
        if [[ ",${vary// /}," != *",$required_vary_token,"* ]]; then
            printf 'nginx-sensitive-routing-smoke: protected Vary is incomplete\n' >&2
            return 1
        fi
    done
    if ! python3 - "$body" "$expected_code" <<'PY'
import json
import pathlib
import sys

try:
    payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)
raise SystemExit(
    0
    if isinstance(payload, dict) and payload.get("code") == sys.argv[2]
    else 1
)
PY
    then
        printf 'nginx-sensitive-routing-smoke: protected JSON error code is unexpected\n' >&2
        return 1
    fi
}

# Direct WordPress code must never reach FastCGI. These probes cover ordinary,
# mixed-case, PATH_INFO and normalized percent-encoded extension forms.
assert_status 404 "/wp-content/mu-plugins/shuzijun-app-content.php"
assert_status 404 "/wp-content/mu-plugins/shuzijun-app-content.PHP"
assert_status 404 "/wp-content/mu-plugins/shuzijun-app-content.php/path-info"
assert_status 404 "/wp-content/mu-plugins/shuzijun-app-content%2ephp"
assert_status 404 "/wp-content/mu-plugins/vendor/shuzijun/app-content/class-shuzijun-app-content-api.php"
assert_status 404 "/wp-content/mu-plugins/vendor/shuzijun/app-content/trait-shuzijun-app-collaboration.php"
assert_status 404 "/wp-content/mu-plugins/vendor/shuzijun/app-content/trait-shuzijun-app-fan-endpoints.php"
assert_status 404 "/wp-content/mu-plugins/vendor/shuzijun/app-content/trait-shuzijun-app-fan-identity.php"
assert_status 404 "/wp-content/mu-plugins/vendor/shuzijun/app-content/trait-shuzijun-app-content-delivery.php"

# The pretty route is authoritative from the caller's perspective: on the
# primary it reaches local WordPress and on the standby Nginx proxies it to the
# primary. Query-form routes miss that proxy, so the authority returns the
# normal 401 while a standby must fail closed locally with an explicit 503.
if [[ "$origin_role" == www ]]; then
    assert_secure_api_error 401 fan_session_required \
        "/wp-json/shuzijun/v1/app-content"
    if [[ "$node_role" == authority ]]; then
        query_status=401
        query_code=fan_session_required
    else
        query_status=503
        query_code=yishu_account_authority_unavailable
    fi
    assert_secure_api_error "$query_status" "$query_code" \
        "/index.php?rest_route=%2Fshuzijun%2Fv1%2Fapp-content"
    assert_secure_api_error "$query_status" "$query_code" \
        "/?rest_route=%2Fshuzijun%2Fv1%2Fapp-content"
fi

printf 'nginx-sensitive-routing-smoke: passed origin=%s role=%s node-role=%s\n' \
    "$base_url" "$origin_role" "$node_role"
