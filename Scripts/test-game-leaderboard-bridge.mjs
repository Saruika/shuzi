import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { buildRules, rulesDigest, parsePredicate, evaluateAST, replayRules, outputPath, STAT_KEYS } from './export-game-rules.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const files = ['events.js', 'endings.js', 'main.js'];
const scripts = await Promise.all(files.map(async name => ({ name, source: await readFile(path.join(root, 'Yishu/Resources/GameAssets/js', name), 'utf8') })));
const rules = JSON.parse(await readFile(outputPath, 'utf8'));
const plain = value => JSON.parse(JSON.stringify(value));

function client({ hasBridge = true, throws = false } = {}) {
  let clock = 0, timerID = 0;
  const timers = new Map(), nodes = new Map();
  const messages = [], rawMessages = [], forbidden = [];
  let attempts = 0;
  class Element {
    constructor() {
      this.children = []; this.style = {}; this.dataset = {}; this.disabled = false;
      this.className = ''; this.textContent = '';
      this.classList = { add() {}, remove() {}, toggle() {} };
    }
    append(...children) { this.children.push(...children); }
    appendChild(child) { this.append(child); }
    replaceChildren(...children) { this.children = [...children]; }
    querySelectorAll(selector) { return selector === 'button' ? this.children : []; }
    setAttribute() {}
    scrollIntoView() {}
  }
  const node = id => { if (!nodes.has(id)) nodes.set(id, new Element()); return nodes.get(id); };
  const context = vm.createContext({
    document: { hidden: false, getElementById: node, createElement: () => new Element(), querySelector: selector => selector === '.question-card' ? node('card') : null, querySelectorAll: () => [], addEventListener() {} },
    performance: { now: () => clock }, addEventListener() {}, scrollTo() {},
    setTimeout(callback, delay = 0) { const id = ++timerID; timers.set(id, { at: clock + delay, callback }); return id; },
    clearTimeout(id) { timers.delete(id); },
  });
  context.window = context;
  for (const name of ['fetch', 'XMLHttpRequest', 'WebSocket', 'EventSource', 'localStorage', 'sessionStorage', 'indexedDB', 'navigator']) {
    Object.defineProperty(context, name, { get() { forbidden.push(name); throw new Error(name); } });
  }
  if (hasBridge) context.webkit = { messageHandlers: new Proxy({ gameLeaderboard: { postMessage(body) {
    attempts++;
    if (throws) throw new Error('Host unavailable');
    rawMessages.push(body); messages.push(plain(body));
  } } }, { get(target, key) { if (key !== 'gameLeaderboard') { forbidden.push(String(key)); throw new Error('Wrong bridge'); } return target[key]; } }) };
  for (const { name, source } of scripts) new vm.Script(source, { filename: name }).runInContext(context);
  const api = vm.runInContext(`({
    state, origins: ORIGINS, endings: ENDINGS,
    begin(origin) { returnToIntro(); disclaimerAccepted = true; state.origin = origin; renderIdentity(); startGame(); },
    choose(index) { chooseOption(getCurrentEvent().opts[index]); },
    prepare: prepareLeaderboardRun,
    trace() { return [...choiceTrace]; },
    restart: returnToIntro
  })`, context);
  return {
    ...api, messages, rawMessages, forbidden, nodes, attempts: () => attempts,
    flush() {
      let count = 0;
      while (timers.size) {
        assert.ok(++count < 100, 'Unexpected timer loop');
        const [id, task] = [...timers].sort((a, b) => a[1].at - b[1].at)[0];
        timers.delete(id); clock = task.at; task.callback();
      }
    },
    run(origin, choose) {
      api.begin(origin);
      for (let index = 0; index < 108 && !api.state.dead; index++) { api.choose(choose(index)); this.flush(); }
      assert.equal(api.state.dead, true);
      return plain({ stats: Object.fromEntries(STAT_KEYS.map(key => [key, api.state[key]])), flags: api.state.flags, ending: api.state.ending.id, score: api.state.score, trace: api.trace() });
    },
  };
}

test('the generated life-v1 manifest is stable, current, and contains data/finite AST rather than executable predicates', async () => {
  assert.deepEqual(await buildRules(), rules);
  assert.equal(rules.version, 'life-v1');
  assert.equal(rulesDigest(rules), rules.rulesHash);
  assert.match(rules.rulesHash, /^[a-f0-9]{64}$/);
  assert.equal(rules.events.length, 108);
  assert.equal(rules.endings.length, 28);
  assert.equal(rules.origins.length, 6);
  assert.doesNotMatch(JSON.stringify(rules), /=>|\beval\s*\(|\bfunction\b|nickname|token|email/);
  const reordered = Object.fromEntries(Object.entries(rules).reverse());
  assert.equal(rulesDigest(reordered), rules.rulesHash);
  const mutated = structuredClone(rules); mutated.events[0].options[0].delta.事业++;
  assert.notEqual(rulesDigest(mutated), rules.rulesHash);
});

test('the predicate parser rejects executable or unknown expressions and preserves boolean precedence', () => {
  for (const source of [
    '(s) => process.exit()', '(s) => s["健康"] > 0', '(s) => s.健康 = 0',
    '(s) => s.constructor > 0', '(s) => s.未知 > 0', '(s) => s.健康 > 0; true',
    '(s) => s.健康 > Infinity', '(s) => { return true; }', '(s) => s.健康 >= 0 /* comment */',
  ]) assert.throws(() => parsePredicate(source), source);
  const ast = parsePredicate('(s) => s.健康 <= 0 || s.贪腐 >= 80 && s.事业 > 30');
  assert.equal(ast.op, 'or');
  assert.equal(ast.args[1].op, 'and');
  assert.equal(evaluateAST(ast, { 健康: 90, 贪腐: 80, 事业: 30 }), false);
  assert.equal(evaluateAST(ast, { 健康: 0, 贪腐: 0, 事业: 0 }), true);
});

test('no message is emitted before an ending; a completed run emits one two-field defensive copy', () => {
  const app = client(); app.begin('peasant'); app.choose(0); app.flush();
  assert.equal(app.messages.length, 0);
  app.run('peasant', index => index === 2 ? 1 : 0);
  assert.equal(app.messages.length, 1);
  assert.deepEqual(Object.keys(app.messages[0]).sort(), ['choices', 'origin']);
  assert.equal(app.messages[0].origin, 'peasant');
  assert.equal(app.messages[0].choices.length, 108);
  assert.ok(app.messages[0].choices.every(index => Number.isInteger(index) && index >= 0 && index < 4));
  app.prepare(); app.prepare();
  assert.equal(app.messages.length, 1);
  app.rawMessages[0].choices[0] = 3;
  assert.equal(app.trace()[0], 0, 'Host-side mutation cannot alter the in-memory game trace');
  assert.equal(app.nodes.get('ending-stats').children.length, 9, 'Original six stats and two journey counters precede the extra score');
  assert.deepEqual(app.forbidden, []);
});

test('the terminal choice is included for early failure and reset cannot append a previous run to the next one', () => {
  const app = client();
  const failed = app.run('business', index => index < 20 ? 3 : 2);
  assert.equal(failed.ending, 'fall_death');
  assert.equal(app.messages[0].choices.length, 62);
  assert.equal(app.state.totalAnswered, 61, 'Original immediate-ending counter behavior remains unchanged');
  app.restart();
  assert.equal(app.trace().length, 0);
  app.run('teacher', index => index === 2 ? 1 : 0);
  assert.equal(app.messages.length, 2);
  assert.equal(app.messages[1].origin, 'teacher');
  assert.equal(app.messages[1].choices.length, 108);
  assert.equal(app.messages[1].choices[0], 0);
});

test('an absent or failing native adapter cannot block an original ending and is never retried automatically', () => {
  for (const options of [{ hasBridge: false }, { throws: true }]) {
    const app = client(options);
    const result = app.run('peasant', index => index === 2 ? 1 : 0);
    assert.equal(result.ending, 'top_human');
    assert.equal(result.score, 12966);
    app.prepare(); app.prepare();
    assert.equal(app.attempts(), options.throws ? 1 : 0);
    assert.equal(app.messages.length, 0);
    assert.deepEqual(app.forbidden, []);
  }
});

test('server replay accepts only terminal bounded routes and ignores all client-side claimed scores by construction', () => {
  assert.throws(() => replayRules(rules, 'unknown', [0]));
  for (const choices of [[], [true], [-1], [4], [0.1], ['0'], Array(109).fill(0)]) {
    assert.throws(() => replayRules(rules, 'peasant', choices));
  }
  assert.throws(() => replayRules(rules, 'peasant', [0]), /not reached an ending/);
  const death = Array.from({ length: 62 }, (_, index) => index < 20 ? 3 : 2);
  assert.equal(replayRules(rules, 'business', death).ending.id, 'fall_death');
  assert.throws(() => replayRules(rules, 'business', [...death, 0]), /continues after/);
});

test('all 28 exported predicates agree with the original checks across boundary and seeded states', () => {
  const app = client();
  const values = [0, 1, 5, 15, 20, 25, 29, 30, 39, 40, 49, 50, 59, 60, 69, 70, 79, 80, 84, 85, 89, 90, 94, 95, 100];
  let seed = 14217;
  for (let sample = 0; sample < 4096; sample++) {
    const stats = Object.fromEntries(STAT_KEYS.map(key => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return [key, values[seed % values.length]]; }));
    for (const [index, ending] of rules.endings.entries()) {
      assert.equal(evaluateAST(ending.check, stats), app.endings[index].check(stats), ending.id);
    }
  }
});

test('JSON replay matches the shipped original rules for every origin on 768 deterministic routes', () => {
  const app = client();
  let seed = 73017, routeCount = 0;
  for (const origin of rules.origins) {
    for (let sample = 0; sample < 128; sample++) {
      const result = app.run(origin.id, index => {
        if (sample < 4) return sample;
        if (sample === 4) return index === 2 ? 1 : 0;
        seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
        return seed >>> 30;
      });
      const replay = replayRules(rules, origin.id, result.trace);
      assert.deepEqual(replay.stats, result.stats, `${origin.id}/${sample} stats`);
      assert.deepEqual(replay.flags, result.flags, `${origin.id}/${sample} flags`);
      assert.equal(replay.ending.id, result.ending, `${origin.id}/${sample} ending`);
      assert.equal(replay.score, result.score, `${origin.id}/${sample} score`);
      routeCount++;
    }
  }
  assert.equal(routeCount, 768);
  assert.deepEqual(app.forbidden, []);
});
