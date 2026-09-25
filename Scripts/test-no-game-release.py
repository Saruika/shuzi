#!/usr/bin/env python3
"""Reject game entry points, client APIs and resources in the current App.

The removed client fixtures and generation scripts must remain absent.
This source gate is complemented by check-distribution-package.py on exports.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLIENT_MARKERS = re.compile(
    r"EmbeddedGame|GameLeaderboard|GameResultBridge|GameRunPayload|GameRunOutcome|"
    r"gameLeaderboard|gameLeaderboardContext|fetchGameLeaderboard|submitGameScore|"
    r"deleteGameScore|removeGameScore|fan/game|about-embedded-game|presentsEmbeddedGame|"
    r"embeddedGameAccess|gameLeaderboardEntry|GameAssets"
)


class NoGameReleaseTests(unittest.TestCase):
    def test_current_app_has_no_game_implementation_or_api(self):
        sources = list((ROOT / 'Yishu').rglob('*.swift'))
        self.assertTrue(sources, 'App sources must be inspected')
        for path in sources:
            with self.subTest(path=path.relative_to(ROOT)):
                self.assertNotRegex(path.name, r'(?i)game')
                self.assertNotRegex(path.read_text(), CLIENT_MARKERS)

    def test_about_page_has_no_game_or_ranking_entry(self):
        source = (ROOT / 'Yishu/Views/AboutView.swift').read_text()
        self.assertNotRegex(source, r'小游戏|宦海浮沉录|排行榜|游戏入口')

    def test_game_resources_and_fixtures_are_not_app_resources(self):
        for path in (ROOT / 'Yishu').rglob('*'):
            with self.subTest(path=path.relative_to(ROOT)):
                self.assertNotRegex(path.name, r'(?i)GameAssets|legacy-game|GameReference|game-rules')
        project = (ROOT / 'Yishu.xcodeproj/project.pbxproj').read_text()
        self.assertNotRegex(project, CLIENT_MARKERS)
        self.assertNotRegex(project, r'GameReference|legacy-game-assets|Server/tests/fixtures|game-rules-v1')

    def test_removed_game_fixtures_and_generation_scripts_stay_absent(self):
        for name in ('YishuTests/GameReference', 'Server/tests/fixtures/legacy-game-assets',
                     'Scripts/export-game-rules.mjs', 'Scripts/test-embedded-game-parity.mjs',
                     'Scripts/test-embedded-game-lifecycle.mjs', 'Scripts/test-game-leaderboard-bridge.mjs',
                     'Scripts/test-game-leaderboard-php.mjs'):
            with self.subTest(path=name):
                self.assertFalse((ROOT / name).exists(), name)
        gate = (ROOT / 'Scripts/security-check.sh').read_text()
        for script in ('test-no-game-release.py', 'test-distribution-package.py'):
            self.assertIn(script, gate)
        self.assertNotRegex(gate, r'export-game-rules|test-embedded-game|test-game-leaderboard')


if __name__ == '__main__':
    unittest.main(verbosity=2)
