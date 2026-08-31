#!/usr/bin/env python3
"""Pin stateful account API traffic to the authoritative WordPress node.

Tencent CDN's global backup origin is retained for ordinary website and media
continuity. The account API cannot safely fail over per request because the two
WordPress databases are synchronized in batches rather than shared in real
time. This path rule therefore fails closed if the authoritative node is down.

Run on the managed Shanghai origin host:
    sudo python3 configure-account-api-origin.py apply
    sudo python3 configure-account-api-origin.py remove
"""

import importlib.machinery
import json
import sys
import time


DOMAIN = "www.shuzijun.com.cn"
ACCOUNT_API_PATH = "/wp-json/shuzijun/v1"
PRIMARY_ORIGIN = "101.43.79.80"
WORKER_PATH = "/usr/local/sbin/shuzijun-cdn-publish-worker"
TARGET_RULE = {
    "RuleType": "directory",
    "RulePaths": [ACCOUNT_API_PATH],
    "Origin": [PRIMARY_ORIGIN],
}


def load_rules(worker):
    response = worker.api_call(
        "DescribeDomainsConfig",
        {
            "Filters": [{"Name": "domain", "Value": [DOMAIN]}],
            "Offset": 0,
            "Limit": 10,
        },
    )
    domains = response.get("Domains", []) or []
    if len(domains) != 1 or domains[0].get("Domain") != DOMAIN:
        raise SystemExit("unexpected CDN domain lookup result")
    origin = domains[0].get("Origin") or {}
    if origin.get("Origins") != [PRIMARY_ORIGIN]:
        raise SystemExit("authoritative origin changed; refusing update")
    rules = origin.get("PathBasedOrigin") or []
    if not isinstance(rules, list):
        raise SystemExit("unexpected path-origin configuration")
    return rules


if len(sys.argv) != 2 or sys.argv[1] not in {"apply", "remove"}:
    raise SystemExit("usage: configure-account-api-origin.py apply|remove")

worker = importlib.machinery.SourceFileLoader(
    "shuzijun_cdn_worker", WORKER_PATH
).load_module()
current_rules = load_rules(worker)
other_rules = [rule for rule in current_rules if rule != TARGET_RULE]
desired_rules = other_rules + ([TARGET_RULE] if sys.argv[1] == "apply" else [])

if current_rules == desired_rules:
    print(f"account-api-origin mode={sys.argv[1]} state=already-current")
    raise SystemExit(0)

worker.api_call(
    "ModifyDomainConfig",
    {
        "Domain": DOMAIN,
        "Route": "Origin.PathBasedOrigin",
        "Value": json.dumps({"update": desired_rules}, separators=(",", ":")),
    },
)

for _ in range(60):
    if load_rules(worker) == desired_rules:
        print(
            f"account-api-origin mode={sys.argv[1]} state=applied "
            f"rule_count={len(desired_rules)}"
        )
        break
    time.sleep(5)
else:
    raise SystemExit("CDN path-origin update did not converge")
