// Cross-language execution: the actual bundled PHP rules loader/interpreter,
// not a PHP-shaped reimplementation. All input is synthetic and offline.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { outputPath, replayRules } from './export-game-rules.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const rules = JSON.parse(await readFile(outputPath, 'utf8'));
const adapter = path.join(root, 'Server/tests/game-leaderboard-replay.php');

function phpReplay(vectors) {
  const reply = spawnSync(process.env.GAME_PHP_BIN || 'php', ['-n', adapter], {
    cwd: root, input: vectors.map(value => JSON.stringify(value)).join('\n') + '\n',
    encoding: 'utf8', timeout: 60_000, maxBuffer: 16 * 1024 * 1024,
  });
  assert.ifError(reply.error);
  assert.equal(reply.status, 0, reply.stderr || reply.stdout);
  assert.equal(reply.stderr, '');
  const lines = reply.stdout.trim().split('\n').map(line => JSON.parse(line));
  assert.equal(lines.length, vectors.length, 'Every route must execute; no silent skip');
  return lines;
}

test('PHP and independently checked JS rules agree on 1,536 terminal routes across all six origins', () => {
  const vectors = [], expected = [];
  let seed = 9172026;
  for (const origin of rules.origins) {
    for (let sample = 0; sample < 256; sample++) {
      const choices = [];
      let result;
      // Stop exactly at the first terminal choice, including early endings.
      for (let index = 0; index < 108; index++) {
        seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
        choices.push(sample < 4 ? sample : sample === 4 ? (index === 2 ? 1 : 0) : seed >>> 30);
        try { result = replayRules(rules, origin.id, choices); break; }
        catch (error) { assert.equal(error.message, 'Route has not reached an ending'); }
      }
      assert.ok(result, 'Route must terminate');
      vectors.push({ origin: origin.id, choices }); expected.push(result);
    }
  }
  const actual = phpReplay(vectors);
  assert.equal(actual.length, 1536);
  assert.ok(expected.some(value => value.answered === 108));
  assert.ok(expected.some(value => value.answered < 108));
  actual.forEach((reply, index) => {
    assert.equal(reply.ok, true, `Route ${index}`);
    const got = reply.result, want = expected[index];
    assert.equal(got.rulesVersion, rules.version);
    assert.equal(got.rulesHash, rules.rulesHash);
    assert.equal(got.origin, want.origin);
    assert.equal(got.answered, want.answered);
    assert.deepEqual(got.stats, want.stats);
    // PHP encodes an empty associative array as [], without changing semantics.
    assert.deepEqual(Object.entries(got.flags), Object.entries(want.flags));
    assert.equal(got.endingID, want.ending.id);
    assert.equal(got.endingTitle, want.ending.title);
    assert.equal(got.score, want.score);
  });
});

test('the actual PHP interpreter rejects malformed, incomplete and after-ending routes', () => {
  const choices = [[], [true], [false], [1.5], ['1'], [-1], [4], null,
    { 0: 0 }, Array(109).fill(0), [0]];
  const vectors = choices.map(value => ({ origin: 'peasant', choices: value }));
  vectors.push({ origin: 'unknown', choices: [0] }, { origin: true, choices: [0] });
  const early = [];
  for (let index = 0; index < 108; index++) {
    early.push(index < 20 ? 3 : 2);
    try { replayRules(rules, 'business', early); break; } catch { /* Incomplete. */ }
  }
  assert.ok(early.length < 108);
  vectors.push({ origin: 'business', choices: [...early, 0] });
  for (const reply of phpReplay(vectors)) assert.equal(reply.ok, false);
});
