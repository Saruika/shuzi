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
assert '"admin-launch-poster-skip-decoration" : "launch-poster-skip"' in source
assert 'Button(action: dismiss) { skipLabel }' in source
assert 'if isPreview {\n                    skipLabel' in source
assert ".scaledToFit()" in source and ".scaledToFill()" in source

copy = source.split("struct LaunchPosterTextBlock: View {", 1)[1]
copy = copy.split("private struct LaunchPosterDismissTaskID", 1)[0]
assert "Capsule()" not in copy, "Do not restore the decorative dash before the eyebrow"
for field in ("eyebrow", "title", "subtitle"):
    assert f"Text(poster.{field})" in copy, "Managed copy must remain editable"

catalog = (root / "Yishu/Models/Portfolio.swift").read_text()
posters = catalog.split("static let launchPosters = [", 1)[1].split("static let showreel", 1)[0]
assert posters.count('subtitle: LaunchPosterDefaultCopy.subtitle') == 3
assert 'static let subtitle = "很高兴，在这里遇见你。"' in catalog
assert "镜头之内，自有叙事。" not in posters

admin = (root / "Yishu/Views/AdminView.swift").read_text()
preview = admin.split("struct LaunchPosterAdminPreview: View {", 1)[1].split("#if DEBUG", 1)[0]
assert "LaunchPosterCanvas(" in preview and "LaunchPosterCanvas(" in source
assert "LaunchPosterWindowSafeArea.resolvedInsets" in preview
assert "LaunchPosterWindowSafeArea.resolvedInsets" in source
assert "imageTargetSize: layout.size" in preview, "Small previews must not decode window-sized textures"
assert "LaunchPosterTextBlock" not in preview, "Admin must not maintain an independent typography layout"
assert "LinearGradient" not in preview and "AdminMediaPreview(" not in preview
assert ".task" not in preview and "LaunchPosterView(" not in preview, "Previews must never run launch dismissal timers"
assert ".allowsHitTesting(false)" in preview, "Preview's scaled controls must not intercept editor touches"
assert "compact: true" not in preview and ".aspectRatio(9 / 16" not in preview
upload = admin.split("private func uploadLaunchPoster", 1)[1].split("private func replaceLaunchPoster", 1)[0]
assert ".newDraft(imageURL: media.sourceURL)" in upload
assert "SEASONAL POSTER" not in upload and "镜头之内，自有叙事。" not in upload
print("launch-poster-contract: shared canvas and copy, timer-free responsive preview passed")
