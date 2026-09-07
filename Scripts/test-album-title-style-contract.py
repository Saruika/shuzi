#!/usr/bin/env python3
"""Keep album heading blocks plain without changing gallery ordinal styling."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / "Yishu/Views/PortfolioViews.swift").read_text()
for start, end in (("private struct PortfolioGridCard", "struct PortfolioDetailView"),
                   ("private struct PortfolioHeroArtwork", "private struct PortfolioGalleryTile")):
    block = source.split(start, 1)[1].split(end, 1)[0]
    assert "Text(portfolio.title)" in block, "Keep the existing album name"
    assert "PortfolioCaptionPalette.current.title" in block, "Keep the existing theme color"
    for effect in (".shadow(", ".modifier(PortfolioCaptionLegibility", ".background(",
                   "LinearGradient(", "RadialGradient(", ".blur("):
        assert effect not in block, f"Album headings must remain plain: {start}: {effect}"

grid = source.split("private struct PortfolioGridCard", 1)[1].split("struct PortfolioDetailView", 1)[0]
hero = source.split("private struct PortfolioHeroArtwork", 1)[1].split("private struct PortfolioGalleryTile", 1)[0]
assert ".font(.system(.title3, design: .serif))" in grid and ".padding(14)" in grid
assert ".font(.system(.largeTitle, design: .serif))" in hero
assert ".padding(.horizontal, 22)" in hero and ".padding(.bottom, 24)" in hero
ordinal = source.split("private struct PortfolioGalleryTile", 1)[1].split("\nprivate struct", 1)[0]
assert ".modifier(PortfolioCaptionLegibility())" in ordinal, "Do not change photo ordinal styling"
print("album-title-style: plain grid/detail headings; font, color, placement and ordinals preserved")
