#!/usr/bin/env python3
"""Prevent outer scroll padding / opaque search-strip regressions."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
theme = (root / 'Yishu/App/AppTheme.swift').read_text()
grid = (root / 'Yishu/Views/PortfolioViews.swift').read_text().split('struct PortfolioGridView', 1)[1].split('private func refreshContent', 1)[0]
clearance = theme.split('private struct FloatingTabBarScrollClearance', 1)[1].split('private struct StableDetailTabBar', 1)[0]
assert 'content.padding(' not in clearance, 'Reserve space inside scroll content, never outside its viewport'
assert 'contentMargins(.bottom, 24, for: .scrollContent)' in clearance
assert 'contentMargins(.bottom, height, for: .scrollContent)' in clearance
assert 'scrollEdgeEffectStyle(.soft, for: .bottom)' in clearance
assert '#available(iOS 26.0, *)' in clearance, 'Keep the iOS 17 fallback'
search = grid.split('.safeAreaInset(edge: .top, spacing: 0)', 1)[1]
assert '.background(AppTheme.ink)' not in search
assert '.background(.ultraThinMaterial)' in search
assert '.scrollClipDisabled()' in grid
assert '.toolbar(.hidden, for: .navigationBar)' in grid
assert '.padding(.top, horizontalSizeClass == .regular ? -1 : 0)' in search
assert 'content.toolbar(UIDevice.current.userInterfaceIdiom == .pad ? .visible : .hidden, for: .tabBar)' in theme
print('scroll-chrome-contract: internal clearance, translucent pinned search and stable iPad tabs passed')
