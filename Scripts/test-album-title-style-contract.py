#!/usr/bin/env python3
"""Keep album heading blocks plain without changing gallery ordinal styling."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / "Yishu/Views/PortfolioViews.swift").read_text()
for start, end in (("private struct PortfolioGridCard", "struct PortfolioDetailView"),
                   ("private struct PortfolioHeroArtwork", "private struct PortfolioGalleryTile")):
    block = source.split(start, 1)[1].split(end, 1)[0]
    assert "Text(portfolio.title)" in block, "Keep the existing album name"
    for effect in (".shadow(", ".modifier(PortfolioCaptionLegibility", ".background(",
                   "LinearGradient(", "RadialGradient(", ".blur("):
        assert effect not in block, f"Album headings must remain plain: {start}: {effect}"

grid = source.split("private struct PortfolioGridCard", 1)[1].split("struct PortfolioDetailView", 1)[0]
hero = source.split("private struct PortfolioHeroArtwork", 1)[1].split("private struct PortfolioGalleryTile", 1)[0]
assert ".font(.system(.title3, design: .serif))" in grid and ".padding(.top, 12)" in grid
assert "VStack(alignment: .leading, spacing: 0)" in grid, "Album captions belong below the artwork"
assert "AppTheme.warmWhite" in grid, "Below-photo captions use theme-aware page text"
assert "ZStack(alignment: .bottomLeading)" not in grid, "Do not overlay album titles on photos"
assert "PortfolioHeroCaption" in hero and "portfolio-hero-caption" in hero
assert "ZStack(alignment: .bottomLeading)" not in hero, "Detail headings also belong below photos"
assert "AppTheme.warmWhite" in hero
assert "heroHeight" not in source, "Do not reintroduce the fixed-height first-photo canvas"
ordinal = source.split("private struct PortfolioGalleryTile", 1)[1].split("\nprivate struct", 1)[0]
assert ".modifier(PortfolioCaptionLegibility())" in ordinal, "Do not change photo ordinal styling"
print("album-title-style: plain below-photo grid captions; full-width detail photo with below-photo captions; ordinals preserved")
