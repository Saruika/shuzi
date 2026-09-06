#!/usr/bin/env python3
"""Read-only exported-device-package gate, not proof of App Store readiness."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
import re
import subprocess
from xml.parsers.expat import ExpatError

BUNDLE = "cn.com.shuzijun.yishu"
TEAM = "6F34K54BYJ"


class PackageCheckError(ValueError):
    """Only fixed check identifiers, never a tool response or profile value."""


def require(condition: bool, code: str) -> None:
    if not condition:
        raise PackageCheckError(code)


def check_metadata(info: dict, entitlements: dict, profile: dict,
                   privacy: dict, version: str, build: str, now: datetime) -> None:
    require(info.get("CFBundleIdentifier") == BUNDLE, "bundle_identifier_mismatch")
    require(info.get("CFBundleShortVersionString") == version, "marketing_version_mismatch")
    require(info.get("CFBundleVersion") == build, "build_number_mismatch")
    require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"], "not_device_distribution")
    require(info.get("UIDeviceFamily") == [1, 2], "missing_phone_or_tablet")
    require(info.get("MinimumOSVersion") == "17.0", "deployment_target_changed")
    ats = info.get("NSAppTransportSecurity", {})
    require(isinstance(ats, dict)
            and not any(ats.get(key, False) for key in ("NSAllowsArbitraryLoads", "NSAllowsArbitraryLoadsForMedia",
                                                       "NSAllowsArbitraryLoadsInWebContent", "NSAllowsLocalNetworking"))
            and not ats.get("NSExceptionDomains", {}), "insecure_transport")
    require(privacy.get("NSPrivacyTracking") is False
            and privacy.get("NSPrivacyTrackingDomains") == [], "tracking_declaration_changed")
    require(isinstance(profile.get("Entitlements"), dict), "profile_entitlements_missing")
    require(profile.get("TeamIdentifier") == [TEAM], "profile_team_mismatch")
    require("ProvisionedDevices" not in profile and not profile.get("ProvisionsAllDevices", False),
            "not_app_store_profile")
    expiry = profile.get("ExpirationDate")
    require(isinstance(expiry, datetime), "profile_expiry_missing")
    require(expiry.replace(tzinfo=expiry.tzinfo or timezone.utc) > now, "profile_expired")
    for rights in (entitlements, profile["Entitlements"]):
        require(rights.get("application-identifier") == TEAM + "." + BUNDLE, "application_identifier_mismatch")
        require(rights.get("com.apple.developer.team-identifier") == TEAM, "entitlement_team_mismatch")
        require(rights.get("get-task-allow") is False, "debugger_entitlement_present")
        require(rights.get("aps-environment") == "production", "push_not_production")
        require(rights.get("com.apple.developer.weatherkit") is True, "weatherkit_entitlement_missing")
        require(rights.get("com.apple.developer.applesignin") == ["Default"], "apple_login_entitlement_missing")


def command(arguments: list[str]) -> bytes:
    # Fixed Apple tools, no shell. Never forward stderr: a profile/tool error
    # can contain certificate identities, device IDs or local account paths.
    result = subprocess.run(arguments, capture_output=True, check=False, timeout=30)
    require(result.returncode == 0, "apple_tool_failed")
    return result.stdout


def read_plist(path: Path) -> dict:
    require(path.is_file() and not path.is_symlink(), "missing_or_linked_metadata")
    return decode_plist(path.read_bytes())


def decode_plist(data: bytes) -> dict:
    try:
        value = plistlib.loads(data)
    except (ValueError, TypeError, ExpatError, OverflowError):
        raise PackageCheckError("invalid_metadata_encoding") from None
    require(isinstance(value, dict), "invalid_metadata_shape")
    return value


def check_package(app: Path, version: str, build: str) -> dict:
    require(app.is_absolute() and app.is_dir() and app.suffix == ".app"
            and not app.is_symlink(), "absolute_exported_app_required")
    info = read_plist(app / "Info.plist")
    privacy = read_plist(app / "PrivacyInfo.xcprivacy")
    profile_path = app / "embedded.mobileprovision"
    require(profile_path.is_file() and not profile_path.is_symlink(), "distribution_profile_missing")
    command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    entitlements = decode_plist(command(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)]))
    profile = decode_plist(command(["/usr/bin/security", "cms", "-D", "-i", str(profile_path)]))
    check_metadata(info, entitlements, profile, privacy, version, build, datetime.now(timezone.utc))
    require(not any(path.suffix.lower() in {".jpg", ".jpeg", ".heic", ".webp", ".avif", ".p8", ".p12", ".pem", ".key"}
                    or path.name.startswith((".env", "AuthKey_"))
                    for path in app.rglob("*") if path.is_file()), "content_or_key_file_in_package")
    # Only fixed, non-sensitive results leave this process. The profile and
    # signing metadata never enter logs or a generated report.
    return {"packageCheck": "passed", "version": version, "build": build,
            "pushEnvironment": "production", "appleLogin": True, "weatherKit": True,
            "submissionReady": "not_assessed", "liveServices": "not_assessed"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    args = parser.parse_args()
    try:
        require(re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", args.version) is not None, "invalid_expected_version")
        require(re.fullmatch(r"[1-9][0-9]*", args.build) is not None, "invalid_expected_build")
        print(json.dumps(check_package(args.app, args.version, args.build), ensure_ascii=False))
        return 0
    except PackageCheckError as error:
        print(json.dumps({"packageCheck": "failed", "check": str(error)}))
        return 1
    except (OSError, ValueError, TypeError, AttributeError, OverflowError, subprocess.SubprocessError):
        # Do not print exception values or parser fragments containing input.
        print("distribution-package-check: failed; inspect the package locally (private details suppressed)")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
