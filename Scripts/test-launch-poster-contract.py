#!/usr/bin/env python3
"""Keep the launch poster still and its introductory copy distinct from Home."""
from pathlib import Path


root = Path(__file__).resolve().parents[1]
source = (root / "Yishu/Views/LaunchPosterView.swift").read_text()
for transform in ("artworkScale", ".scaleEffect(", ".rotationEffect(",
                  ".rotation3DEffect(", ".matchedGeometryEffect("):
    assert transform not in source, f"Launch artwork must not animate its geometry: {transform}"
assert ".opacity(remoteImageIsVisible ? 1 : 0)" in source
assert "poster.displaySeconds" in source
assert "pausesAutomaticDismissal" in source
assert '.accessibilityIdentifier("launch-poster-skip")' in source
assert ".scaledToFit()" in source and ".scaledToFill()" in source

copy = source.split("struct LaunchPosterTextBlock: View {", 1)[1]
copy = copy.split("private struct LaunchPosterDismissTaskID", 1)[0]
assert "Capsule()" not in copy, "Do not restore the decorative dash before the eyebrow"
for field in ("eyebrow", "title", "subtitle"):
    assert f"Text(poster.{field})" in copy, "Managed copy must remain editable"

catalog = (root / "Yishu/Models/Portfolio.swift").read_text()
posters = catalog.split("static let launchPosters = [", 1)[1].split("static let showreel", 1)[0]
assert posters.count('subtitle: "很高兴，在这里遇见你。"') == 3
assert "镜头之内，自有叙事。" not in posters
print("launch-poster-contract: still artwork, no decorative dash, distinct managed copy passed")
