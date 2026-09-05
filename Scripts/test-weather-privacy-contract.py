#!/usr/bin/env python3
"""Check that every weather/geocoding path goes through coarse data minimization."""
import plistlib
from pathlib import Path


root = Path(__file__).resolve().parents[1]
info = plistlib.loads((root / "Yishu/Info.plist").read_bytes())
assert info["NSLocationDefaultAccuracyReduced"] is True
source = (root / "Yishu/Services/LocalWeatherStore.swift").read_text()
assert "locationManager.desiredAccuracy = kCLLocationAccuracyReduced" in source
assert "requestTemporaryFullAccuracyAuthorization" not in source
load = source.split("private func loadWeather(for location: CLLocation) {", 1)[1]
load = load.split("private func currentWeatherWithRetry", 1)[0]
guard = load.index("guard let location = WeatherLocationPrivacy.approximate(location)")
for operation in ("location.distance(from:", "self.locationName(for: location)",
                  "self.currentWeatherWithRetry(for: location)", "self.lastLocation = location"):
    assert guard < load.index(operation)
print("weather-privacy-contract: coarse default, sanitized services and memory cache passed")
