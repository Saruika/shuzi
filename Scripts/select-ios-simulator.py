#!/usr/bin/env python3
"""Choose a simulator template by OS version, never by simctl listing order.

Reads `xcrun simctl list devices available --json` from stdin. No device is
created, booted, erased or deleted here. An explicit version fails closed.
"""
import argparse
import json
import re
import sys


def version_tuple(value):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value):
        raise ValueError("invalid runtime version")
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))


def select_device(payload, family, requested="latest"):
    expected = None if requested == "latest" else version_tuple(requested)
    candidates = []
    for runtime, devices in payload["devices"].items():
        match = re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-([0-9-]+)", runtime)
        if not match:
            continue
        version = version_tuple(match[1].replace("-", "."))
        if expected is not None and version != expected:
            continue
        for device in devices:
            name = device.get("name", "")
            identifier = device.get("udid", "")
            if not device.get("isAvailable") or not name.startswith(family + " "):
                continue
            if not re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", identifier):
                continue
            preferred = (" Pro Max" in name if family == "iPhone" else "Pro 13-inch" in name)
            candidates.append((version, preferred, name, identifier))
    if not candidates:
        raise ValueError("no available simulator matches the requested family and runtime")
    # The OS version is the primary key: an older Pro Max must not beat a
    # newer supported iPhone, and input order must never change the result.
    return max(candidates)[-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--family", choices=("iPhone", "iPad"), required=True)
    parser.add_argument("--runtime", default="latest")
    args = parser.parse_args()
    try:
        print(select_device(json.load(sys.stdin), args.family, args.runtime))
        return 0
    except (ValueError, KeyError, TypeError, AttributeError):
        print("simulator-selection: no valid matching simulator; no older-runtime fallback", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
