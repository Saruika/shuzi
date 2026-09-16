import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

// Execute the acquired source, not a rewritten rules engine. The DOM below does
// not render pixels, invoke DOMContentLoaded, or provide a remote SDK/network.
const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sourceDirectory = process.env.ORIGINAL_PARITY_SOURCE_DIR || path.join(repository, 'YishuTests/GameReference');
const migratedDirectory = process.env.ORIGINAL_PARITY_MIGRATED_DIR || path.join(repository, 'Yishu/Resources/GameAssets/js');
const files = ['events.js', 'endings.js', 'main.js'];
const source = Object.fromEntries(await Promise.all(files.map(async name => [name, await readFile(path.join(sourceDirectory, name), 'utf8')])));
const migrated = Object.fromEntries(await Promise.all(files.map(async name => [name, await readFile(path.join(migratedDirectory, name), 'utf8')])));
const visibleStats = ['贪腐', '财富', '民心', '健康', '人脉', '事业'];
const initial = {
  peasant: [0, 0, 55, 90, 30, 0, 70, 0],
  worker: [0, 1, 50, 90, 33, 2, 70, 0],
  teacher: [0, 0, 50, 95, 30, 0, 75, 3],
  official: [2, 5, 50, 90, 38, 0, 70, 0],
  business: [3, 8, 50, 90, 35, 0, 70, 0],
  soldier: [0, 0, 50, 100, 30, 3, 72, 0],
};

function makeRuntime(scripts) {
  const elements = new Map();
  const timers = new Map();
  const externalAccess = [];
  let timerId = 0;
  let clock = 0;
  class Element {
    constructor(id = '') {
      this.id = id;
      this.children = [];
      this.style = {};
      this.dataset = {};
      this.attributes = new Map();
      this.disabled = false;
      this.hidden = false;
      this.textContent = '';
      this.innerHTML = '';
      const classes = new Set();
      this.classList = {
        add: (...items) => items.forEach(item => classes.add(item)),
        remove: (...items) => items.forEach(item => classes.delete(item)),
        contains: item => classes.has(item),
        toggle: (item, force) => {
          const enabled = force ?? !classes.has(item);
          if (enabled) classes.add(item); else classes.delete(item);
          return enabled;
        },
      };
    }
    set innerHTML(value) { this.html = value; this.children = []; }
    get innerHTML() { return this.html; }
    append(...children) { this.children.push(...children); }
    appendChild(child) { this.children.push(child); return child; }
    replaceChildren(...children) { this.children = [...children]; }
    setAttribute(name, value) { this.attributes.set(name, String(value)); }
    removeAttribute(name) { this.attributes.delete(name); }
    getAttribute(name) { return this.attributes.get(name) ?? null; }
    querySelector() { return null; }
    querySelectorAll() { return []; }
    addEventListener() {}
    removeEventListener() {}
    focus() {}
    scrollIntoView() {}
  }
  const document = {
    hidden: false, visibilityState: 'visible',
    getElementById(id) {
      if (!elements.has(id)) elements.set(id, new Element(id));
      return elements.get(id);
    },
    createElement: tag => new Element(tag),
    querySelector: selector => selector === '.question-card' ? document.getElementById('question-card-fixture') : null,
    querySelectorAll: () => [],
    addEventListener() {}, // Never start identity, disclaimer or host integration.
    removeEventListener() {},
  };
  function reject(name) {
    externalAccess.push(name);
    throw new Error(`Host dependency reached by rules test: ${name}`);
  }
  const ToySDK = new Proxy({ profile: { nickname: 'rules-fixture' } }, {
    get(target, key) { return key in target ? target[key] : reject(`ToySDK.${String(key)}`); },
  });
  const context = vm.createContext({
    document, ToySDK, console, performance: { now: () => clock },
    setTimeout(callback, delay = 0) {
      const id = ++timerId;
      timers.set(id, { callback, at: clock + Number(delay), delay: Number(delay) });
      return id;
    },
    clearTimeout: id => timers.delete(id),
    setInterval: () => reject('setInterval'), clearInterval() {},
    addEventListener() {}, removeEventListener() {}, scrollTo() {},
    requestAnimationFrame: callback => { callback(); return 0; },
    cancelAnimationFrame() {},
    matchMedia: () => ({ matches: false, addEventListener() {} }),
    confirm: () => true, alert: () => reject('alert'),
  });
  context.window = context;
  for (const key of ['fetch', 'XMLHttpRequest', 'WebSocket', 'EventSource', 'localStorage', 'sessionStorage', 'indexedDB', 'caches', 'navigator']) {
    Object.defineProperty(context, key, { get: () => reject(key), set: () => reject(key) });
  }
  for (const name of files) new vm.Script(scripts[name], { filename: name }).runInContext(context, { timeout: 2000 });
  // Only suppress the original ending's external social adapter, retaining the
  // exact pre-SDK score calculation. Core rules and showEnding remain original.
  vm.runInContext(`
    if (typeof initEndingSocial === 'function') {
      initEndingSocial = function () { state.score = computeScore(); };
    }
    globalThis.__parity = {
      origins: ORIGINS, events: ALL_EVENTS, endings: ENDINGS, state,
      applyDelta, checkImmediateEnd, evaluateEnding, computeScore,
      async start(originId) {
        resetState();
        state.origin = originId;
        if (typeof disclaimerAccepted !== 'undefined') disclaimerAccepted = true;
        if (typeof activeScreen !== 'undefined') {
          showScreen('intro');
          renderIdentity();
        }
        await startGame();
      },
      choose(index) { chooseOption(getCurrentEvent().opts[index]); },
      chooseSynthetic(option) { chooseOption(option); },
      snapshot() {
        return JSON.stringify({
          origin: state.origin,
          stats: ['贪腐','财富','民心','健康','人脉','事业','廉洁','声望'].map(key => state[key]),
          currentIdx: state.currentIdx, totalAnswered: state.totalAnswered,
          events: state.events, flags: state.flags, phase: state.phase,
          dead: state.dead, ending: state.ending && state.ending.id,
          score: state.score, topFlags: state.topFlags,
          log: state.log,
        });
      }
    };
  `, context);
  const api = context.__parity;
  return {
    ...api, externalAccess, timers,
    async start(origin) { timers.clear(); clock = 0; await api.start(origin); this.flush(); },
    step(index) { api.choose(index); this.flush(); return api.snapshot(); },
    flush() {
      let count = 0;
      while (timers.size) {
        assert.ok(++count < 100, 'Unexpected recurring timer in a single rules step');
        const [id, task] = [...timers].sort((a, b) => a[1].at - b[1].at || a[0] - b[0])[0];
        timers.delete(id); clock = task.at; task.callback();
      }
    },
  };
}

const baseline = makeRuntime(source);
const plain = value => JSON.parse(JSON.stringify(value));
const stateVector = runtime => [...visibleStats, '廉洁', '声望'].map(key => runtime.state[key]);

test('acquired source hashes identify the reviewed version; catalog is 108 events / 432 options / 28 endings', () => {
  const hashes = {
    'events.js': 'df10acc91240a31e9ebe336a39aecfd55716a27f82d6a866394db6153261471e',
    'endings.js': 'ae4f1173f961922e4bc72b65cca513fa5e633e3a5e93797d7e4c4fcfe9d960af',
    'main.js': 'c2b012490403b85258925d405c6fa52a69236e478758490a62cb7c2909fc7bae',
  };
  for (const name of files) assert.equal(createHash('sha256').update(source[name]).digest('hex'), hashes[name]);
  assert.equal(baseline.events.length, 108);
  assert.deepEqual(plain(baseline.events.map(event => event.id)), Array.from({ length: 108 }, (_, i) => `q${String(i + 1).padStart(3, '0')}`));
  assert.ok(baseline.events.every(event => event.opts.length === 4));
  assert.equal(baseline.events.flatMap(event => event.opts).length, 432);
  assert.equal(baseline.endings.length, 28);
  assert.equal(new Set(baseline.endings.map(ending => ending.id)).size, 28);
  assert.equal(new Set(baseline.events.flatMap(event => event.opts).map(option => option.flag).filter(Boolean)).size, 173);
});

test('all six origins preserve the original visible and hidden initial values', async () => {
  for (const [origin, values] of Object.entries(initial)) {
    await baseline.start(origin);
    assert.deepEqual(stateVector(baseline), values, origin);
    assert.equal(baseline.state.currentIdx, 0);
    assert.equal(baseline.state.totalAnswered, 0);
    assert.deepEqual(plain(baseline.state.flags), {});
  }
});

test('applyDelta clamps existing values and ignores undefined energy, risk, family and unknown keys', async () => {
  await baseline.start('peasant');
  baseline.applyDelta({ 健康: -1000, 贪腐: 1000, 财富: -10, 精力: -5, 风险: 10, 家庭: 5, unknown: 3 });
  assert.deepEqual(stateVector(baseline), [100, 0, 55, 0, 30, 0, 70, 0]);
  for (const key of ['精力', '风险', '家庭', 'unknown']) assert.equal(Object.hasOwn(baseline.state, key), false);
  const absent = new Set(baseline.events.flatMap(event => event.opts).flatMap(option => Object.keys(option.delta)).filter(key => baseline.state[key] === undefined));
  assert.deepEqual([...absent].sort(), ['家庭', '精力', '风险'].sort());
});

test('each choice overwrites direct integrity/reputation deltas with the derived formulas before ending checks', async () => {
  await baseline.start('teacher');
  baseline.chooseSynthetic({ text: 'fixture', delta: { 廉洁: -100, 声望: 100, 贪腐: 10, 财富: 20, 事业: 30 }, flag: 'fixture' });
  baseline.flush();
  assert.deepEqual(stateVector(baseline), [10, 20, 50, 95, 30, 30, 90, 48]);
  assert.equal(baseline.state.flags.fixture, 1);
  baseline.chooseSynthetic({ text: 'fixture', delta: {}, flag: 'fixture' });
  baseline.flush();
  assert.equal(baseline.state.flags.fixture, 2);
  assert.deepEqual(plain(baseline.state.events), [], 'The source does not append to its events field');
});

test('immediate corruption 85 differs from final 80, and immediate failure precedence is corruption / health / public support', async () => {
  await baseline.start('peasant');
  for (const [corruption, immediate, final] of [[79, null, 'fall_prison'], [80, null, 'fall_death'], [84, null, 'fall_death'], [85, 'fall_death', 'fall_death']]) {
    Object.assign(baseline.state, { 贪腐: corruption, 健康: 90, 民心: 50, 事业: 20, 财富: 0 });
    assert.equal(baseline.checkImmediateEnd(), immediate);
    assert.equal(baseline.evaluateEnding().id, final);
  }
  Object.assign(baseline.state, { 贪腐: 85, 健康: 0, 民心: 0, 事业: 100 });
  assert.equal(baseline.checkImmediateEnd(), 'fall_death');
  baseline.state.贪腐 = 0;
  assert.equal(baseline.checkImmediateEnd(), 'death_sick');
  baseline.state.健康 = 90;
  assert.equal(baseline.checkImmediateEnd(), 'fall_resigned');
  assert.notEqual(baseline.evaluateEnding().id, 'fall_resigned', 'Final public-support condition also requires career < 30');
  Object.assign(baseline.state, { 民心: 5, 事业: 29 });
  assert.equal(baseline.checkImmediateEnd(), null);
  assert.equal(baseline.evaluateEnding().id, 'fall_resigned');
});

test('flags do not select branches or endings; catalog phases and advancement follow event order', async () => {
  await baseline.start('peasant');
  const before = baseline.evaluateEnding().id;
  baseline.state.flags = Object.fromEntries(baseline.events.flatMap(event => event.opts).filter(option => option.flag).map(option => [option.flag, 100]));
  assert.equal(baseline.evaluateEnding().id, before);
  assert.ok(baseline.endings.every(ending => !/flags/.test(ending.check.toString())));
  const phases = {};
  for (const event of baseline.events) phases[event.phase] = (phases[event.phase] || 0) + 1;
  assert.deepEqual(Object.values(phases), [12, 14, 16, 16, 18, 16, 16]);
  for (let i = 0; i < 13; i++) {
    baseline.step(i === 2 ? 1 : 0);
    assert.equal(baseline.state.currentIdx, i + 1);
    assert.equal(baseline.state.phase, baseline.events[i].phase, 'Phase records the answered event, not the next event');
  }
});

test('original delayed progression is 350ms, final settlement 800ms, ending presentation 600ms', async () => {
  await baseline.start('peasant');
  baseline.choose(0);
  assert.ok([...baseline.timers.values()].some(timer => timer.delay === 350));
  baseline.flush();
  Object.assign(baseline.state, { currentIdx: 107, totalAnswered: 107 });
  baseline.choose(0);
  assert.ok([...baseline.timers.values()].some(timer => timer.delay === 800));
  baseline.flush();
  assert.equal(baseline.state.dead, true);
  await baseline.start('peasant');
  baseline.state.贪腐 = 85;
  baseline.choose(0);
  assert.ok([...baseline.timers.values()].some(timer => timer.delay === 600));
  assert.equal(baseline.state.currentIdx, 0);
  assert.equal(baseline.state.totalAnswered, 0, 'Immediate termination occurs before nextEvent increments counters');
  baseline.flush();
});

test('documented 108-question and 62-question observations match the acquired source', async () => {
  await baseline.start('peasant');
  for (let i = 0; i < 108; i++) {
    baseline.step(i === 2 ? 1 : 0);
    if (i === 11) assert.deepEqual(stateVector(baseline).slice(0, 6), [2, 0, 75, 81, 25, 10]);
  }
  assert.deepEqual(stateVector(baseline).slice(0, 6), [0, 0, 100, 80, 3, 86]);
  assert.equal(baseline.state.ending.id, 'top_human');
  assert.equal(baseline.state.totalAnswered, 108);
  await baseline.start('business');
  for (let i = 0; i < 62; i++) {
    baseline.step(i < 20 ? 3 : 2);
    if (i === 60) { assert.equal(baseline.state.贪腐, 80); assert.equal(baseline.state.dead, false); }
  }
  assert.deepEqual(stateVector(baseline).slice(0, 6), [88, 41, 32, 85, 53, 52]);
  assert.equal(baseline.state.ending.id, 'fall_death');
  assert.equal(baseline.state.currentIdx, 61);
  assert.equal(baseline.state.totalAnswered, 61);
});

// Predicate rectangles use integral visible stats in [0,100]. The only hidden
// condition is integrity >=70 under corruption <=15, which the source formula
// always satisfies (minimum 74.5 even with wealth=100). This checks predicate
// shadowing, NOT whether a 108-choice game route can reach a witness state.
function predicateBox(ending) {
  const box = visibleStats.map(() => [0, 100]);
  const source = ending.check.toString();
  if (/=>\s*true\s*$/.test(source)) return box;
  const clauses = source.slice(source.indexOf('=>') + 2).trim().split(/\s*&&\s*/);
  for (const clause of clauses) {
    const match = /^s\.([^\s]+)\s*(>=|<=|<|>)\s*(\d+)$/.exec(clause);
    assert.ok(match, `Unsupported condition in shadow audit: ${clause}`);
    const [, stat, operator, raw] = match;
    const value = Number(raw);
    if (stat === '廉洁') {
      assert.equal(ending.id, 'top_pure');
      assert.equal(operator, '>='); assert.equal(value, 70);
      assert.match(source, /s\.贪腐 <= 15/);
      assert.ok(100 - 15 * 0.7 - 100 * 0.15 >= 70);
      continue;
    }
    const index = visibleStats.indexOf(stat);
    assert.notEqual(index, -1);
    if (operator === '>=') box[index][0] = value;
    if (operator === '>') box[index][0] = value + 1;
    if (operator === '<=') box[index][1] = value;
    if (operator === '<') box[index][1] = value - 1;
  }
  return box;
}

function subtractBox(box, earlier) {
  const intersection = box.map(([lo, hi], i) => [Math.max(lo, earlier[i][0]), Math.min(hi, earlier[i][1])]);
  if (intersection.some(([lo, hi]) => lo > hi)) return [box];
  const remains = [];
  const middle = box.map(range => [...range]);
  for (let i = 0; i < middle.length; i++) {
    const [lo, hi] = intersection[i];
    if (middle[i][0] < lo) {
      const lower = middle.map(range => [...range]); lower[i][1] = lo - 1;
      remains.push(lower); middle[i][0] = lo;
    }
    if (middle[i][1] > hi) {
      const upper = middle.map(range => [...range]); upper[i][0] = hi + 1;
      remains.push(upper); middle[i][1] = hi;
    }
  }
  return remains;
}

test('array order resolves equal-rank endings; identify fully shadowed predicates without claiming route reachability', async t => {
  const sameRank = baseline.endings.filter(ending => ending.rank === 22).map(ending => ending.id);
  assert.deepEqual(plain(sameRank), ['fall_public', 'corrupt_pure']);
  const boxes = baseline.endings.map(predicateBox);
  const shadowed = [];
  for (let index = 0; index < boxes.length; index++) {
    let remains = [boxes[index]];
    for (let prior = 0; prior < index && remains.length; prior++) remains = remains.flatMap(box => subtractBox(box, boxes[prior]));
    if (!remains.length) { shadowed.push(baseline.endings[index].id); continue; }
    const witness = Object.fromEntries(visibleStats.map((key, i) => [key, remains[0][i][0]]));
    witness.廉洁 = Math.max(0, Math.min(100, 100 - witness.贪腐 * 0.7 - witness.财富 * 0.15));
    assert.equal(baseline.endings.find(ending => ending.check(witness)).id, baseline.endings[index].id);
  }
  assert.deepEqual(shadowed, []);
  t.diagnostic('All 28 predicates have an unshadowed bounded-state witness; this is not proof of gameplay reachability.');
});

function seededChoices(seed) {
  let value = seed >>> 0;
  return Array.from({ length: 108 }, () => {
    value = (Math.imul(value, 1664525) + 1013904223) >>> 0;
    return value >>> 30;
  });
}

async function compareRoute(original, port, origin, choices, label) {
  await original.start(origin);
  await port.start(origin);
  assert.equal(port.snapshot(), original.snapshot(), `${label}: initial state`);
  let steps = 0;
  for (const optionIndex of choices) {
    if (original.state.dead) break;
    const expected = original.step(optionIndex);
    const actual = port.step(optionIndex);
    if (actual !== expected) assert.equal(actual, expected, `${label}: after question ${steps + 1}, choice ${optionIndex}`);
    steps++;
  }
  assert.equal(original.state.dead, true, `${label}: route did not finish`);
  return steps;
}

test('migration preserves complete event and ending data byte-for-byte', () => {
  for (const name of ['events.js', 'endings.js']) assert.equal(migrated[name], source[name], name);
});

test('migration matches original immediate/final predicates and applyDelta on boundary states', async () => {
  const port = makeRuntime(migrated);
  await baseline.start('peasant');
  await port.start('peasant');
  for (const corruption of [0, 59, 60, 69, 70, 79, 80, 84, 85, 100]) {
    for (const health of [0, 1, 20, 21, 30, 31, 40, 41, 100]) {
      for (const support of [0, 1, 5, 6, 20, 21, 30, 31, 60, 70, 80, 90, 100]) {
        for (const career of [29, 30, 49, 50, 59, 60, 69, 70, 79, 80, 89, 90, 94, 95]) {
          const state = { 贪腐: corruption, 健康: health, 民心: support, 事业: career, 财富: 70, 人脉: 70, 廉洁: 70 };
          Object.assign(baseline.state, state); Object.assign(port.state, state);
          assert.equal(port.checkImmediateEnd(), baseline.checkImmediateEnd());
          assert.equal(port.evaluateEnding().id, baseline.evaluateEnding().id);
        }
      }
    }
  }
  for (const origin of Object.keys(initial)) {
    await baseline.start(origin); await port.start(origin);
    for (const delta of [{ 健康: -1000, 贪腐: 1000, 精力: -5 }, { 贪腐: -1000, 廉洁: 1000, 风险: 20, 家庭: 5 }, { 声望: -1000, 财富: 1000, 人脉: -1000 }]) {
      baseline.applyDelta(delta); port.applyDelta(delta);
      assert.equal(port.snapshot(), baseline.snapshot());
    }
  }
  assert.deepEqual(port.externalAccess, []);
});

test('all six roles match the original for fixed-choice and observed routes at every step', async t => {
  const port = makeRuntime(migrated);
  let steps = 0;
  for (const origin of Object.keys(initial)) {
    const routes = [0, 1, 2, 3].map(choice => Array(108).fill(choice));
    routes.push(Array.from({ length: 108 }, (_, i) => i === 2 ? 1 : 0));
    routes.push(Array.from({ length: 108 }, (_, i) => i < 20 ? 3 : 2));
    for (const [index, route] of routes.entries()) steps += await compareRoute(baseline, port, origin, route, `${origin}/fixed-${index}`);
  }
  assert.deepEqual(port.externalAccess, []);
  t.diagnostic(`36 fixed routes matched across ${steps} answered choices.`);
});

test('3072 seeded routes match original stats, hidden metrics, flags, counters, logs and ending after each choice', async t => {
  const port = makeRuntime(migrated);
  const endings = new Set();
  let steps = 0;
  for (const origin of Object.keys(initial)) {
    for (let seed = 1; seed <= 512; seed++) {
      steps += await compareRoute(baseline, port, origin, seededChoices(seed), `${origin}/seed-${seed}`);
      endings.add(baseline.state.ending.id);
    }
  }
  assert.deepEqual(port.externalAccess, []);
  t.diagnostic(`3072 seeded routes / ${steps} answered choices; observed ending IDs: ${[...endings].sort().join(', ')}. This is sampled coverage, not all paths.`);
});

test('rule execution never reaches the remote SDK, network, browser storage or identity bootstrap', () => {
  assert.deepEqual(baseline.externalAccess, []);
});
