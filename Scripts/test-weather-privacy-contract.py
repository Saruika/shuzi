#!/usr/bin/env python3
"""Prevent retired weather/location capabilities from returning to production."""
import plistlib
from pathlib import Path

root = Path(__file__).resolve().parents[1]
info = plistlib.loads((root / "Yishu/Info.plist").read_bytes())
assert not any(key.startswith("NSLocation") for key in info)
entitlements = plistlib.loads((root / "Yishu/Yishu.entitlements").read_bytes())
assert "com.apple.developer.weatherkit" not in entitlements
manifest = plistlib.loads((root / "Yishu/Resources/PrivacyInfo.xcprivacy").read_bytes())
for item in manifest["NSPrivacyCollectedDataTypes"]:
    assert "Location" not in item["NSPrivacyCollectedDataType"]
for path in (root / "Yishu").rglob("*.swift"):
    source = path.read_text()
    for retired in ("import WeatherKit", "CLLocationManager", "LocalWeatherStore"):
        assert retired not in source, (path, retired)
project = (root / "Yishu.xcodeproj/project.pbxproj").read_text()
assert "WeatherKit" not in project
assert "NSLocation" not in project
print("weather-removal-contract: no service, location permissions or privacy declarations")
