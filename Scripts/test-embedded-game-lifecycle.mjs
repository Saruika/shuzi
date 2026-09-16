import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

// Deterministic lifecycle tests execute the shipped JS with a small DOM and a
// foreground clock. This does not render WebKit or substitute for device QA.
const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const assets = path.join(repository, 'Yishu/Resources/GameAssets');
const html = await readFile(path.join(assets, 'index.html'), 'utf8');
const css = await readFile(path.join(assets, 'css/style.css'), 'utf8');
const scripts = await Promise.all(['events.js', 'endings.js', 'main.js'].map(async name => ({
  name, source: await readFile(path.join(assets, 'js', name), 'utf8'),
})));

function runtime() {
  let now = 0;
  let timerID = 0;
  const timers = new Map();
  const elements = new Map();
  const docListeners = new Map();
  const winListeners = new Map();
  const externalAccess = [];
  let focused = null;

  function listeners(map, type, fn) {
    if (!map.has(type)) map.set(type, []);
    map.get(type).push(fn);
  }
  function dispatch(map, type, values = {}) {
    const event = { type, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; }, ...values };
    for (const callback of map.get(type) ?? []) callback(event);
    return event;
  }
  function matches(element, selector) {
    if (selector.startsWith('.')) return element.classList.contains(selector.slice(1));
    return element.tagName === selector.toUpperCase();
  }
  class Element {
    constructor(tag = 'div', id = '') {
      this.tagName = tag.toUpperCase();
      this.id = id;
      this.children = [];
      this.parentElement = null;
      this.style = {};
      this.dataset = {};
      this.attributes = new Map();
      this.listeners = new Map();
      this.disabled = false;
      this.hidden = false;
      this.inert = false;
      this.open = false;
      this.removed = false;
      this.textContent = '';
      this.classes = new Set();
      this.classList = {
        add: (...items) => items.forEach(item => this.classes.add(item)),
        remove: (...items) => items.forEach(item => this.classes.delete(item)),
        contains: item => this.classes.has(item),
        toggle: (item, force) => {
          const next = force ?? !this.classes.has(item);
          if (next) this.classes.add(item); else this.classes.delete(item);
          return next;
        },
      };
    }
    set className(value) { this.classes = new Set(value.split(/\s+/).filter(Boolean)); }
    get className() { return [...this.classes].join(' '); }
    append(...children) { for (const child of children) { child.parentElement = this; this.children.push(child); } }
    appendChild(child) { this.append(child); return child; }
    replaceChildren(...children) { this.children = []; this.append(...children); }
    setAttribute(name, value) { this.attributes.set(name, String(value)); }
    getAttribute(name) { return this.attributes.get(name) ?? null; }
    querySelectorAll(selector) {
      return this.children.flatMap(child => [
        ...(matches(child, selector) ? [child] : []), ...child.querySelectorAll(selector),
      ]);
    }
    querySelector(selector) { return this.querySelectorAll(selector)[0] ?? null; }
    addEventListener(type, fn) { listeners(this.listeners, type, fn); }
    focus() { focused = this; }
    scrollIntoView() { this.scrollCount = (this.scrollCount ?? 0) + 1; }
    remove() { this.removed = true; }
    showModal() { this.open = true; }
    close() { this.open = false; dispatch(this.listeners, 'close'); }
    click() { if (!this.disabled && !this.inert && !this.removed) this.onclick?.({ target: this }); }
  }
  for (const [, tag, id] of html.matchAll(/<([a-z][a-z0-9]*)\b[^>]*\bid="([^"]+)"/g)) {
    elements.set(id, new Element(tag, id));
  }
  for (const name of ['intro', 'game', 'ending']) elements.get(`screen-${name}`).className = 'screen' + (name === 'intro' ? ' active' : '');
  elements.get('btn-accept').disabled = true;
  elements.get('btn-start').disabled = true;
  const questionCard = new Element('section');
  questionCard.className = 'question-card';
  const statRows = new Map(['贪腐', '财富', '民心', '健康', '人脉', '事业'].map(key => {
    const row = new Element();
    row.className = 'stat-row';
    row.dataset.stat = key;
    const fill = new Element(); fill.className = 'stat-fill';
    const num = new Element('span'); num.className = 'stat-num';
    row.append(fill, num);
    return [key, row];
  }));
  const document = {
    hidden: false, visibilityState: 'visible',
    getElementById: id => elements.get(id) ?? null,
    createElement: tag => new Element(tag),
    querySelector(selector) {
      if (selector === '.question-card') return questionCard;
      const key = /^\.stat-row\[data-stat="([^"]+)"\]$/.exec(selector)?.[1];
      return statRows.get(key) ?? null;
    },
    querySelectorAll: selector => [...elements.values()].filter(element => matches(element, selector)),
    addEventListener: (type, fn) => listeners(docListeners, type, fn),
  };
  const context = vm.createContext({
    document, performance: { now: () => now }, console,
    setTimeout(callback, delay = 0) {
      const id = ++timerID;
      timers.set(id, { callback, at: now + Number(delay), delay: Number(delay) });
      return id;
    },
    clearTimeout: id => timers.delete(id),
    addEventListener: (type, fn) => listeners(winListeners, type, fn),
    scrollTo() {},
  });
  context.window = context;
  const reject = name => { externalAccess.push(name); throw new Error(`Unexpected external capability: ${name}`); };
  for (const name of ['fetch', 'XMLHttpRequest', 'WebSocket', 'EventSource', 'localStorage', 'sessionStorage', 'indexedDB', 'caches', 'navigator', 'webkit', 'ToySDK']) {
    Object.defineProperty(context, name, { get: () => reject(name), set: () => reject(name) });
  }
  for (const { name, source } of scripts) new vm.Script(source, { filename: name }).runInContext(context);
  vm.runInContext(`globalThis.__lifecycle = {
    state, origins: ORIGINS, events: ALL_EVENTS,
    chooseOption, startGame, returnToIntro, renderQuestion,
    status() { return { activeScreen, gameStarted, disclaimerAccepted, choiceLocked, runGeneration, pending: runTasks.size }; },
  };`, context);
  const api = context.__lifecycle;
  function advance(milliseconds) {
    const until = now + milliseconds;
    let executions = 0;
    while (true) {
      const next = [...timers].filter(([, task]) => task.at <= until).sort((a, b) => a[1].at - b[1].at || a[0] - b[0])[0];
      if (!next) break;
      assert.ok(++executions < 1000, 'Unexpected timer loop');
      const [id, task] = next;
      timers.delete(id);
      now = task.at;
      task.callback();
    }
    now = until;
  }
  const result = {
    api, elements, timers, externalAccess, advance,
    focused: () => focused,
    snapshot: () => JSON.stringify(api.state),
    click: id => { assert.ok(elements.has(id), id); elements.get(id).click(); },
    options: () => [...elements.get('options').children],
    choose: index => elements.get('options').children[index].click(),
    boot: () => dispatch(docListeners, 'DOMContentLoaded'),
    visibility(hidden) {
      document.hidden = hidden;
      document.visibilityState = hidden ? 'hidden' : 'visible';
      dispatch(docListeners, 'visibilitychange');
    },
    page: event => dispatch(winListeners, event),
    cancelRestart: () => dispatch(elements.get('restart-dialog').listeners, 'cancel'),
    enter(origin = 'peasant') {
      this.boot();
      advance(5000);
      this.click('btn-accept');
      const choice = elements.get('origin-list').children.find(item => item.dataset.id === origin);
      assert.ok(choice, origin);
      choice.click();
      this.click('btn-start');
      assert.equal(api.status().activeScreen, 'game');
    },
  };
  return result;
}

test('five foreground seconds are required; hidden time does not accept the entertainment notice or fetch identity', () => {
  const app = runtime(); app.boot();
  app.click('btn-accept'); app.click('btn-start');
  assert.equal(app.api.status().gameStarted, false);
  assert.equal(app.elements.get('screen-intro').inert, true);
  app.advance(2500);
  app.visibility(true); app.advance(60000);
  assert.equal(app.elements.get('btn-accept').disabled, true);
  assert.equal(app.timers.size, 0);
  app.visibility(false); app.advance(2499);
  assert.equal(app.elements.get('btn-accept').disabled, true);
  app.advance(1);
  assert.equal(app.elements.get('btn-accept').disabled, false);
  app.click('btn-accept');
  assert.equal(app.api.status().disclaimerAccepted, true);
  assert.equal(app.elements.get('screen-intro').inert, false);
  assert.equal(app.focused().id, 'btn-start');
  assert.equal(app.elements.get('disclaimer').removed, true);
  assert.deepEqual(app.externalAccess, []);
});

test('all six origin buttons work and rapid start taps cannot apply their bonus twice', () => {
  for (const id of ['peasant', 'worker', 'teacher', 'official', 'business', 'soldier']) {
    const app = runtime(); app.enter(id);
    assert.equal(app.api.state.origin, id);
    const before = app.snapshot();
    app.click('btn-start'); app.api.startGame();
    assert.equal(app.snapshot(), before, id);
    assert.equal(app.options().length, 4);
    assert.equal(app.elements.get('q-id').textContent, '#001');
    assert.equal(app.api.state.name, '本地匿名玩家');
  }
});

test('double taps, direct replays and old question button callbacks apply one choice only', () => {
  const app = runtime(); app.enter();
  const originalOption = app.api.events[0].opts[0];
  const oldButton = app.options()[0];
  app.choose(0);
  const chosen = app.snapshot();
  assert.ok(app.options().every(option => option.disabled));
  app.choose(0); oldButton.onclick(); app.api.chooseOption(originalOption);
  assert.equal(app.snapshot(), chosen);
  assert.equal(app.api.state.totalAnswered, 1);
  app.advance(349);
  assert.equal(app.elements.get('q-id').textContent, '#001');
  app.advance(1);
  assert.equal(app.elements.get('q-id').textContent, '#002');
  assert.ok(app.options().every(option => !option.disabled));
  oldButton.onclick(); app.api.chooseOption(originalOption);
  assert.equal(app.snapshot(), chosen);
  app.choose(0); app.advance(350);
  assert.equal(app.api.state.totalAnswered, 2);
  assert.equal(app.elements.get('q-id').textContent, '#003');
});

test('a half-finished transition pauses in background and resumes once without answering another event', () => {
  const app = runtime(); app.enter(); app.choose(0); app.advance(175);
  const chosen = app.snapshot();
  app.visibility(true); app.advance(120000);
  assert.equal(app.timers.size, 0);
  assert.equal(app.elements.get('q-id').textContent, '#001');
  app.api.chooseOption(app.api.events[1].opts[1]);
  assert.equal(app.snapshot(), chosen);
  app.visibility(false); app.advance(174);
  assert.equal(app.elements.get('q-id').textContent, '#001');
  app.advance(1);
  assert.equal(app.elements.get('q-id').textContent, '#002');
  app.advance(120000);
  assert.equal(app.api.state.totalAnswered, 1);
  assert.equal(app.snapshot(), chosen);
  assert.equal(app.api.status().pending, 0);
});

test('overlapping pagehide and visibility signals resume each task once and never bypass the still-hidden state', () => {
  const app = runtime(); app.enter(); app.choose(0); app.advance(100);
  app.page('pagehide'); app.visibility(true); app.advance(12000);
  app.page('pageshow'); app.advance(12000);
  assert.equal(app.timers.size, 0);
  assert.equal(app.elements.get('q-id').textContent, '#001');
  app.visibility(false); app.page('pageshow'); app.visibility(false);
  assert.equal([...app.timers.values()].filter(task => task.delay === 250).length, 1);
  app.advance(250);
  assert.equal(app.elements.get('q-id').textContent, '#002');
  app.advance(60000);
  assert.equal(app.api.state.totalAnswered, 1);
});

test('canceling the restart dialog preserves the run and resumes the remaining transition', () => {
  const app = runtime(); app.enter('teacher'); app.choose(0); app.advance(100);
  const before = app.snapshot();
  app.click('btn-restart'); app.advance(50000);
  assert.equal(app.elements.get('restart-dialog').open, true);
  assert.equal(app.snapshot(), before);
  assert.equal(app.elements.get('q-id').textContent, '#001');
  const event = app.cancelRestart();
  assert.equal(event.defaultPrevented, true);
  assert.equal(app.elements.get('restart-dialog').open, false);
  app.advance(249);
  assert.equal(app.elements.get('q-id').textContent, '#001');
  app.advance(1);
  assert.equal(app.elements.get('q-id').textContent, '#002');
  assert.equal(app.snapshot(), before);
});

test('confirmed restart invalidates timers and detached buttons even after another run starts', () => {
  const app = runtime(); app.enter('official');
  const oldButton = app.options()[0];
  app.choose(0);
  const toast = app.elements.get('hint-toast');
  assert.equal(toast.classList.contains('show'), true);
  assert.ok(toast.textContent.length > 0);
  const callbacks = [...app.timers.values()].map(task => task.callback);
  const generation = app.api.status().runGeneration;
  app.click('btn-restart'); app.click('btn-confirm-restart');
  assert.ok(app.api.status().runGeneration > generation);
  assert.equal(app.api.status().activeScreen, 'intro');
  assert.equal(app.api.state.totalAnswered, 0);
  assert.equal(app.api.state.origin, 'peasant');
  assert.equal(app.timers.size, 0);
  assert.equal(toast.classList.contains('show'), false);
  assert.equal(toast.textContent, '');
  callbacks.forEach(callback => callback()); oldButton.onclick(); app.advance(50000);
  assert.equal(app.api.status().activeScreen, 'intro');
  app.click('btn-start');
  const fresh = app.snapshot();
  callbacks.forEach(callback => callback()); oldButton.onclick(); app.advance(50000);
  assert.equal(app.snapshot(), fresh);
  assert.equal(app.elements.get('q-id').textContent, '#001');
  assert.equal(app.api.status().choiceLocked, false);
  assert.equal(toast.classList.contains('show'), false);
  assert.equal(toast.textContent, '');
});

test('restart during the final 800ms settlement cannot reveal a stale ending in the new run', () => {
  const app = runtime(); app.enter();
  for (let i = 0; i < 107; i++) { app.choose(i === 2 ? 1 : 0); app.advance(350); }
  assert.equal(app.api.state.currentIdx, 107);
  app.choose(0);
  const callbacks = [...app.timers.values()].map(task => task.callback);
  assert.equal(app.api.state.totalAnswered, 108);
  assert.equal(app.api.state.dead, false);
  app.click('btn-restart'); app.click('btn-confirm-restart'); app.click('btn-start');
  callbacks.forEach(callback => callback()); app.advance(50000);
  assert.equal(app.api.state.dead, false);
  assert.equal(app.api.state.ending, null);
  assert.equal(app.api.state.totalAnswered, 0);
  assert.equal(app.api.status().activeScreen, 'game');
});

test('immediate ending presentation also pauses; replay cannot add choices after the run ended', () => {
  const app = runtime(); app.enter('business');
  for (let i = 0; i < 61; i++) { app.choose(i < 20 ? 3 : 2); app.advance(350); }
  const finalButton = app.options()[2];
  app.choose(2);
  assert.equal(app.api.state.dead, true);
  const finalState = app.snapshot();
  app.advance(200); app.visibility(true); app.advance(60000);
  assert.equal(app.api.status().activeScreen, 'game');
  finalButton.onclick();
  assert.equal(app.snapshot(), finalState);
  app.visibility(false); app.advance(399);
  assert.equal(app.api.status().activeScreen, 'game');
  app.advance(1);
  assert.equal(app.api.status().activeScreen, 'ending');
  assert.equal(app.api.state.ending.id, 'fall_death');
  app.click('btn-play-again');
  assert.equal(app.api.status().activeScreen, 'intro');
  assert.equal(app.api.state.dead, false);
});

test('repeated foreground/background cycles do not duplicate pending tasks or change a resting question', () => {
  const app = runtime(); app.enter(); app.choose(0); app.advance(350);
  const before = app.snapshot();
  for (let i = 0; i < 100; i++) {
    app.visibility(true); app.page('pagehide'); app.advance(60000);
    app.page('pageshow'); app.visibility(false); app.advance(20);
    assert.ok(app.timers.size <= 1, 'At most the remaining hint dismissal may be pending');
  }
  app.advance(2000);
  assert.equal(app.snapshot(), before);
  assert.equal(app.elements.get('q-id').textContent, '#002');
  assert.equal(app.timers.size, 0);
  assert.deepEqual(app.externalAccess, []);
});

test('finishing a run and starting another clears the old live-region hint for visual and VoiceOver users', () => {
  const app = runtime(); app.enter();
  for (let i = 0; i < 108; i++) { app.choose(i === 2 ? 1 : 0); app.advance(350); }
  app.advance(1800);
  assert.equal(app.api.status().activeScreen, 'ending');
  const toast = app.elements.get('hint-toast');
  assert.ok(toast.textContent.length > 0, 'Last run has a real choice hint');
  const oldCallbacks = [...app.timers.values()].map(task => task.callback);
  app.click('btn-play-again');
  assert.equal(toast.textContent, '');
  assert.equal(toast.classList.contains('show'), false);
  app.elements.get('origin-list').children.find(origin => origin.dataset.id === 'business').click();
  app.click('btn-start');
  oldCallbacks.forEach(callback => callback());
  app.advance(5000);
  assert.equal(app.api.state.origin, 'business');
  assert.equal(app.elements.get('q-id').textContent, '#001');
  assert.equal(toast.textContent, '');
  assert.equal(toast.classList.contains('show'), false);
});

test('offline document uses classic local scripts and a restrictive CSP compatible with an asset folder', async () => {
  const policy = /http-equiv="Content-Security-Policy" content="([^"]+)"/.exec(html)?.[1];
  assert.ok(policy);
  const directives = new Map(policy.split(';').map(item => item.trim().split(/\s+/)).map(([name, ...values]) => [name, values]));
  for (const directive of ['default-src', 'connect-src', 'img-src', 'font-src', 'object-src', 'frame-src', 'worker-src', 'base-uri', 'form-action']) {
    assert.deepEqual(directives.get(directive), ["'none'"], directive);
  }
  assert.deepEqual(directives.get('script-src'), ["'self'"]);
  assert.deepEqual(directives.get('style-src'), ["'self'", "'unsafe-inline'"]);
  assert.doesNotMatch(html, /<script(?![^>]*\bsrc=)[^>]*>/i);
  assert.doesNotMatch(html, /type="module"|<iframe|<form|\son[a-z]+=/i);
  const paths = [...html.matchAll(/(?:src|href)="([^"]+)"/g)].map(match => match[1]);
  assert.deepEqual(paths, ['css/style.css', 'js/events.js', 'js/endings.js', 'js/main.js']);
  for (const asset of paths) assert.ok((await readFile(path.join(assets, asset))).length > 0);
  const main = scripts.find(script => script.name === 'main.js').source;
  assert.doesNotMatch(main, /localStorage|sessionStorage|indexedDB|fetch\(|postMessage|XMLHttpRequest|toDataURL|innerHTML|webkit|ToySDK/);
  assert.doesNotMatch(css, /@import|url\(/);
});

test('mobile layout keeps document flow, safe areas, touch target sizing and a scrollable short-height disclaimer', () => {
  assert.match(html, /viewport-fit=cover/);
  assert.match(css, /body\s*\{\s*height: auto;\s*min-height: 100svh;/);
  assert.match(css, /padding: env\(safe-area-inset-top\) env\(safe-area-inset-right\) env\(safe-area-inset-bottom\) env\(safe-area-inset-left\)/);
  assert.match(css, /button\s*\{ touch-action: manipulation; min-height: 44px; \}/);
  assert.match(css, /\.disclaimer-card\s*\{\s*max-height: calc\(100dvh[^}]+overflow-y: auto;/);
  assert.match(css, /\.question-card \{ padding: 24px 20px; min-height: 0; \}/);
  assert.match(css, /\.q-desc, \.option-text, \.ending-text \{ overflow-wrap: anywhere; \}/);
  assert.match(css, /prefers-reduced-motion: reduce/);
  assert.doesNotMatch(css, /(?:html|body|\.screen|\.question-card)\s*\{[^}]*overflow(?:-y)?:\s*hidden/);
});

test('short phone landscape puts compact readable status beside the question without constraining vertical scroll', () => {
  const start = css.indexOf('@media (min-width: 601px) and (max-height: 500px)');
  assert.ok(start >= 0, 'Layout is scoped away from narrow portrait and regular-height iPad viewports');
  const end = css.indexOf('@media (hover: none)', start);
  assert.ok(end > start);
  const block = css.slice(start, end);
  assert.match(block, /\.game-main\s*\{\s*display: grid;\s*grid-template-columns: clamp\(180px, 26vw, 220px\) minmax\(0, 1fr\);/);
  assert.match(block, /\.stats-panel \{ position: static; min-width: 0; padding: 14px; \}/);
  assert.match(block, /\.stat-list \{ grid-template-columns: 1fr; gap: 8px; \}/);
  assert.match(block, /\.stat-label, \.stat-num \{ font-size: 12px; \}/);
  assert.match(block, /\.legend-row \{ font-size: 12px;/);
  assert.match(block, /\.question-card \{ min-height: 0; padding: 20px; \}/);
  assert.match(block, /\.option \{ min-height: 44px; padding: 12px 16px; \}/);
  assert.doesNotMatch(block, /overflow(?:-y)?:\s*(?:hidden|clip)|position:\s*(?:fixed|sticky)|(?:max-)?height:\s*\d+(?:vh|dvh|svh)/);
});
