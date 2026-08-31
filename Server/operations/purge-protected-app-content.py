#!/usr/bin/env python3
"""Purge the formerly public App manifest after enabling access control.

This script is intended to run on the managed origin host, where the existing
CDN publishing worker owns the short-lived Tencent API authentication. It does
not read or print credentials and it is deliberately limited to one exact URL.
"""

import importlib.machinery
import time


MANIFEST_URL = "https://www.shuzijun.com.cn/wp-json/shuzijun/v1/app-content"
WORKER_PATH = "/usr/local/sbin/shuzijun-cdn-publish-worker"


worker = importlib.machinery.SourceFileLoader(
    "shuzijun_cdn_worker", WORKER_PATH
).load_module()

for area in ("mainland", "overseas"):
    result = worker.api_call(
        "PurgeUrlsCache",
        {"Urls": [MANIFEST_URL], "Area": area, "UrlEncode": False},
    )
    task_id = str(result.get("TaskId", ""))
    if not task_id:
        raise SystemExit(f"{area} purge task missing")

    for _ in range(90):
        state = worker.api_call(
            "DescribePurgeTasks",
            {"TaskId": task_id, "Area": area, "Offset": 0, "Limit": 20},
        )
        logs = state.get("PurgeLogs", []) or []
        statuses = {str(item.get("Status", "")).lower() for item in logs}
        if "fail" in statuses:
            raise SystemExit(f"{area} purge failed")
        if logs and statuses <= {"done"}:
            print(f"area={area} purge=done url_count=1", flush=True)
            break
        time.sleep(2)
    else:
        raise SystemExit(f"{area} purge timeout")
