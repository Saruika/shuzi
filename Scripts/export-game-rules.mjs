import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const outputPath = path.join(repository, 'Server/vendor/shuzijun/app-content/game-rules-v1.json');
export const STAT_KEYS = Object.freeze(['贪腐', '财富', '民心', '健康', '人脉', '事业', '廉洁', '声望']);

export function canonicalJSON(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonicalJSON(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

export function rulesDigest(rules) {
  const { rulesHash: ignored, ...payload } = rules;
  return createHash('sha256').update(canonicalJSON(payload), 'utf8').digest('hex');
}

// The server receives only this finite comparison/boolean AST, never JavaScript
// source or executable PHP. Reject calls, assignments, computed properties,
// unknown fields, and trailing input instead of trying to interpret them.
export function parsePredicate(source) {
  if (typeof source !== 'string' || source.length > 2048) throw new Error('Unsupported predicate length');
  const arrow = /^\s*(?:\(\s*s?\s*\)|s)\s*=>\s*([\s\S]+?)\s*$/.exec(source);
  if (!arrow) throw new Error('Only a restricted arrow predicate is supported');
  const text = arrow[1];
  const tokens = [];
  let offset = 0;
  while (offset < text.length) {
    const whitespace = /^\s+/.exec(text.slice(offset));
    if (whitespace) { offset += whitespace[0].length; continue; }
    const token = /^(?:s\.[\p{L}_][\p{L}\p{N}_]*|true\b|&&|\|\||>=|<=|===|!==|==|!=|>|<|\(|\)|-?(?:0|[1-9]\d*)(?:\.\d+)?)/u.exec(text.slice(offset));
    if (!token) throw new Error('Unsupported predicate token');
    tokens.push(token[0]);
    if (tokens.length > 256) throw new Error('Predicate is too complex');
    offset += token[0].length;
  }
  let cursor = 0;
  const operators = { '>=': 'gte', '>': 'gt', '<=': 'lte', '<': 'lt', '===': 'eq', '==': 'eq', '!==': 'ne', '!=': 'ne' };
  function atom(depth) {
    if (depth > 16) throw new Error('Predicate nesting is too deep');
    if (tokens[cursor] === '(') {
      cursor++;
      const nested = or(depth + 1);
      if (tokens[cursor++] !== ')') throw new Error('Unbalanced predicate');
      return nested;
    }
    if (tokens[cursor] === 'true') { cursor++; return { op: 'true' }; }
    const statToken = tokens[cursor++];
    const stat = statToken?.startsWith('s.') ? statToken.slice(2) : '';
    if (!STAT_KEYS.includes(stat)) throw new Error('Unknown predicate stat');
    const op = operators[tokens[cursor++]];
    const valueToken = tokens[cursor++];
    if (!op || !/^-?(?:0|[1-9]\d*)(?:\.\d+)?$/.test(valueToken ?? '')) throw new Error('Invalid predicate comparison');
    const value = Number(valueToken);
    if (!Number.isFinite(value)) throw new Error('Non-finite predicate value');
    return { op, stat, value };
  }
  function and(depth) {
    const args = [atom(depth)];
    while (tokens[cursor] === '&&') { cursor++; args.push(atom(depth)); }
    return args.length === 1 ? args[0] : { op: 'and', args };
  }
  function or(depth) {
    const args = [and(depth)];
    while (tokens[cursor] === '||') { cursor++; args.push(and(depth)); }
    return args.length === 1 ? args[0] : { op: 'or', args };
  }
  const ast = or(0);
  if (cursor !== tokens.length) throw new Error('Trailing predicate input');
  return ast;
}

export async function buildRules() {
  const jsDirectory = path.join(repository, 'Yishu/Resources/GameAssets/js');
  const sources = await Promise.all(['events.js', 'endings.js', 'main.js'].map(async name => ({
    name, text: await readFile(path.join(jsDirectory, name), 'utf8'),
  })));
  // Only the checked-in, trusted build assets are evaluated during generation.
  // No DOM callbacks, SDK, account, filesystem or network enter this VM.
  const context = vm.createContext({ document: { addEventListener() {} }, addEventListener() {} });
  context.window = context;
  for (const { name, text } of sources) new vm.Script(text, { filename: name }).runInContext(context, { timeout: 2000 });
  const data = vm.runInContext(`({
    baseStats: Object.fromEntries(['贪腐','财富','民心','健康','人脉','事业','廉洁','声望'].map(key => [key, state[key]])),
    origins: ORIGINS.map(origin => ({ id: origin.id, name: origin.name, bonus: origin.bonus })),
    events: ALL_EVENTS.map(event => ({ id: event.id, phase: event.phase, options: event.opts.map(option => ({ delta: option.delta, flag: option.flag || null })) })),
    endings: ENDINGS.map(ending => ({ id: ending.id, title: ending.title, grade: ending.grade, rank: ending.rank, predicate: ending.check.toString() })),
    gradeBase: GRADE_BASE,
    immediateSource: checkImmediateEnd.toString(),
    scoreSource: computeScore.toString()
  })`, context);
  const plain = JSON.parse(JSON.stringify(data));
  if (plain.origins.length !== 6 || plain.events.length !== 108 || !plain.events.every(event => event.options.length === 4)) {
    throw new Error('Unexpected catalog structure; create and review a new rules version');
  }
  const main = sources.find(source => source.name === 'main.js').text.replace(/\s+/g, '');
  const required = [
    'state.廉洁=clamp(100-state.贪腐*0.7-state.财富*0.15,0,100);',
    'state.声望=Math.round((state.事业*0.5+state.民心*0.3+state.廉洁*0.2));',
    'if(state.贪腐>=85)return\'fall_death\';',
    'if(state.健康<=0)return\'death_sick\';',
    'if(state.民心<=0)return\'fall_resigned\';',
  ];
  if (!required.every(statement => main.includes(statement))) throw new Error('Derived or immediate rules changed; review the exporter');
  const scoring = plain.scoreSource.replace(/\s+/g, '');
  if (!scoring.includes('(state.事业||0)*20+(state.民心||0)*10+(state.财富||0)*5+(state.健康||0)*3+(state.人脉||0)*2-(state.贪腐||0)*30')
      || !scoring.includes('Math.max(-16777216,Math.min(16777215,base+detail))')) {
    throw new Error('Score formula changed; review the exporter');
  }
  const rules = {
    version: 'life-v1',
    maxChoices: plain.events.length,
    baseStats: plain.baseStats,
    origins: plain.origins,
    events: plain.events,
    endings: plain.endings.map(({ predicate, ...ending }) => ({ ...ending, check: parsePredicate(predicate) })),
    immediateEnds: [
      { id: 'fall_death', check: { op: 'gte', stat: '贪腐', value: 85 } },
      { id: 'death_sick', check: { op: 'lte', stat: '健康', value: 0 } },
      { id: 'fall_resigned', check: { op: 'lte', stat: '民心', value: 0 } },
    ],
    derived: {
      integrity: { base: 100, weights: { 贪腐: -0.7, 财富: -0.15 }, order: ['贪腐', '财富'], min: 0, max: 100 },
      reputation: { weights: { 事业: 0.5, 民心: 0.3, 廉洁: 0.2 }, order: ['事业', '民心', '廉洁'], round: 'js-Math.round' },
    },
    score: {
      gradeBase: plain.gradeBase,
      weights: { 事业: 20, 民心: 10, 财富: 5, 健康: 3, 人脉: 2, 贪腐: -30 },
      order: ['事业', '民心', '财富', '健康', '人脉', '贪腐'],
      round: 'js-Math.round', min: -16777216, max: 16777215,
    },
  };
  return { ...rules, rulesHash: rulesDigest(rules) };
}

export function evaluateAST(ast, stats) {
  switch (ast.op) {
    case 'true': return true;
    case 'and': return ast.args.every(arg => evaluateAST(arg, stats));
    case 'or': return ast.args.some(arg => evaluateAST(arg, stats));
    case 'gte': return stats[ast.stat] >= ast.value;
    case 'gt': return stats[ast.stat] > ast.value;
    case 'lte': return stats[ast.stat] <= ast.value;
    case 'lt': return stats[ast.stat] < ast.value;
    case 'eq': return stats[ast.stat] === ast.value;
    case 'ne': return stats[ast.stat] !== ast.value;
    default: throw new Error('Unsupported AST operation');
  }
}

// Independent, finite JSON interpreter for exporter regression tests. The
// production backend implements the same contract without evaluating JS/PHP.
export function replayRules(rules, originID, choices) {
  const origin = rules.origins.find(item => item.id === originID);
  if (!origin || !Array.isArray(choices) || choices.length < 1 || choices.length > rules.maxChoices
      || !choices.every(index => Number.isInteger(index) && index >= 0 && index < 4)) throw new Error('Invalid route');
  const stats = { ...rules.baseStats };
  const flags = {};
  const clamp = (value, min, max) => Math.max(min, Math.min(max, value));
  const apply = delta => {
    for (const [key, value] of Object.entries(delta)) {
      if (Object.hasOwn(stats, key)) stats[key] = clamp(stats[key] + value, 0, 100);
    }
  };
  const weighted = (definition, base = 0) => definition.order.reduce((sum, key) => sum + stats[key] * definition.weights[key], base);
  apply(origin.bonus);
  let ending = null;
  for (let i = 0; i < choices.length; i++) {
    const option = rules.events[i].options[choices[i]];
    apply(option.delta);
    if (option.flag) flags[option.flag] = (flags[option.flag] ?? 0) + 1;
    const integrity = rules.derived.integrity;
    stats.廉洁 = clamp(weighted(integrity, integrity.base), integrity.min, integrity.max);
    stats.声望 = Math.round(weighted(rules.derived.reputation));
    const immediate = rules.immediateEnds.find(item => evaluateAST(item.check, stats));
    if (immediate) {
      if (i !== choices.length - 1) throw new Error('Route continues after its ending');
      ending = rules.endings.find(item => item.id === immediate.id);
      break;
    }
  }
  if (!ending) {
    if (choices.length !== rules.maxChoices) throw new Error('Route has not reached an ending');
    ending = rules.endings.find(item => evaluateAST(item.check, stats));
  }
  if (!ending) throw new Error('No matching ending');
  const detail = Math.round(weighted(rules.score));
  const score = clamp((rules.score.gradeBase[ending.grade] ?? 0) + detail, rules.score.min, rules.score.max);
  return { origin: originID, answered: choices.length, stats, flags, ending: { id: ending.id, title: ending.title, grade: ending.grade }, score };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const rules = await buildRules();
  const output = `${JSON.stringify(rules, null, 2)}\n`;
  if (process.argv.includes('--check')) {
    if (await readFile(outputPath, 'utf8') !== output) throw new Error('Generated rules differ from the checked-in manifest');
    process.stdout.write(`Rules are current: ${rules.version} ${rules.rulesHash}\n`);
  } else {
    await mkdir(path.dirname(outputPath), { recursive: true });
    await writeFile(outputPath, output, 'utf8');
    process.stdout.write(`Exported ${rules.version}: ${rules.events.length} events, ${rules.endings.length} endings; ${rules.rulesHash}\n`);
  }
}
