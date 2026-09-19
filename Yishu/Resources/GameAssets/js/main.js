/* =========================================
   引擎 + UI 主控
   ========================================= */

// 出身定义
const ORIGINS = [
  { id:'peasant', name:'寒门学子', desc:'清白起步，民心较高', bonus:{贪腐:-3, 民心:+5, 财富:-2} },
  { id:'worker',  name:'工薪家庭', desc:'务实稳健，人脉较广', bonus:{人脉:+3, 事业:+2, 财富:+1} },
  { id:'teacher', name:'教师世家', desc:'书香门第，注重声誉', bonus:{声望:+3, 廉洁:+5, 健康:+5} },
  { id:'official',name:'干部子弟', desc:'耳濡目染，人脉深厚', bonus:{人脉:+8, 财富:+5, 贪腐:+2} },
  { id:'business',name:'商人家庭', desc:'家境优渥，资源丰富', bonus:{财富:+8, 人脉:+5, 贪腐:+3} },
  { id:'soldier', name:'军人后代', desc:'作风硬朗，健康强壮', bonus:{健康:+10, 事业:+3, 廉洁:+2} }
];

const STAT_META = [
  { key:'贪腐', max:100, label:'贪腐', invert:true, dangerAbove:80 },
  { key:'财富', max:100, label:'财富' },
  { key:'民心', max:100, label:'民心' },
  { key:'健康', max:100, label:'健康', dangerBelow:20 },
  { key:'人脉', max:100, label:'人脉' },
  { key:'事业', max:100, label:'事业' }
];

// 数值钳制
const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));

// ============== 全局状态 ==============
const state = {
  name: '',
  origin: 'peasant',
  // 6 维数值
  贪腐: 0, 财富: 0, 民心: 50, 健康: 90, 人脉: 30, 事业: 0,
  // 附加（用作结局判定）
  廉洁: 70,
  声望: 0,
  // 元数据
  currentIdx: 0,        // 当前题目序号
  totalAnswered: 0,
  events: [],           // 已作答事件序号索引
  flags: {},            // 关键标记
  log: [],              // 简短的反馈日志（仅供显示）
  phase: '试用期',      // 当前段位
  dead: false,
  ending: null
};

// ============== 本地交互生命周期 ==============
// All progress stays in memory. The single, optional native adapter receives
// only an origin and its choice indexes, never an identity or claimed score.
const LOCAL_PLAYER_NAME = '本局玩家';
let choiceTrace = [];
let didPrepareLeaderboard = false;
let activeScreen = 'intro';
let gameStarted = false;
let disclaimerAccepted = false;
let choiceLocked = false;
let runGeneration = 0;
let pageHidden = false;
let restartOpen = false;
const runTasks = new Map();

function lifecyclePaused(){
  return document.hidden || pageHidden || restartOpen;
}

function cancelRunTask(key){
  const task = runTasks.get(key);
  if(!task) return;
  clearTimeout(task.timer);
  runTasks.delete(key);
}

function armRunTask(key, task){
  if(lifecyclePaused() || task.generation !== runGeneration) return;
  task.startedAt = performance.now();
  task.timer = setTimeout(() => {
    if(task.generation !== runGeneration || runTasks.get(key) !== task) return;
    task.timer = null;
    if(lifecyclePaused()){
      task.remaining = Math.max(0, task.remaining - (performance.now() - task.startedAt));
      return;
    }
    runTasks.delete(key);
    task.callback();
  }, Math.max(1, task.remaining));
}

function scheduleRunTask(key, callback, delay){
  cancelRunTask(key);
  const task = { callback, remaining: delay, startedAt: 0, timer: null, generation: runGeneration };
  runTasks.set(key, task);
  armRunTask(key, task);
}

function pauseRunTasks(){
  for(const task of runTasks.values()){
    if(task.timer === null) continue;
    clearTimeout(task.timer);
    task.timer = null;
    task.remaining = Math.max(0, task.remaining - (performance.now() - task.startedAt));
  }
}

function resumeRunTasks(){
  if(lifecyclePaused()) return;
  for(const [key, task] of runTasks){
    if(task.timer === null) armRunTask(key, task);
  }
}

function invalidateRun(){
  runGeneration++;
  for(const task of runTasks.values()) clearTimeout(task.timer);
  runTasks.clear();
  choiceLocked = false;
  gameStarted = false;
  const toast = document.getElementById('hint-toast');
  if(toast){
    toast.classList.remove('show');
    toast.textContent = '';
  }
}

function textElement(tag, className, text){
  const element = document.createElement(tag);
  element.className = className;
  element.textContent = text;
  return element;
}

// ============== 工具 ==============
function applyDelta(delta){
  for(const k in delta){
    if(state[k] === undefined) continue;
    state[k] = clamp(state[k] + delta[k], 0, 100);
  }
  // 健康为 0 时贪腐不应该涨（一些特殊处理）
  // 事业推动其他指数联动
}

function pushLog(text){
  state.log.unshift({ text, ts: formatTime() });
  if(state.log.length > 30) state.log.length = 30;
}

function formatTime(){
  return `第 ${state.totalAnswered + 1} 题`;
}

// ============== 题目推进 ==============
function getCurrentEvent(){
  if(state.currentIdx >= ALL_EVENTS.length){
    return null; // 全部完成
  }
  return ALL_EVENTS[state.currentIdx];
}

function nextEvent(){
  state.currentIdx++;
  state.totalAnswered++;
  return getCurrentEvent();
}

// ============== 即时阈值检查 ==============
function checkImmediateEnd(){
  if(state.贪腐 >= 85) return 'fall_death';
  if(state.健康 <= 0) return 'death_sick';
  if(state.民心 <= 0) return 'fall_resigned';
  return null;
}

// ============== 结局判定 ==============
function evaluateEnding(){
  // 按 rank 排序，已 ENDINGS 已排好
  for(const e of ENDINGS){
    if(e.check(state)) return e;
  }
  return ENDINGS[ENDINGS.length - 1]; // 兜底
}

// ============== UI 渲染 ==============
function $(id){ return document.getElementById(id); }

function showScreen(name){
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  $(`screen-${name}`).classList.add('active');
  activeScreen = name;
  window.scrollTo({ top: 0, left: 0, behavior: 'instant' });
}

function renderStats(){
  STAT_META.forEach(m => {
    const row = document.querySelector(`.stat-row[data-stat="${m.key}"]`);
    if(!row) return;
    const fill = row.querySelector('.stat-fill');
    const num = row.querySelector('.stat-num');
    const v = state[m.key] || 0;
    fill.style.width = (v / m.max * 100) + '%';
    num.textContent = Math.round(v);
    // 危险态
    row.classList.toggle('danger',
      (m.dangerAbove && v >= m.dangerAbove) ||
      (m.dangerBelow && v <= m.dangerBelow));
  });
}

const FLAG_LABELS = {
  '勤快':'勤劳踏实', '懒':'消极怠工', '稳':'稳扎稳打', '造假':'数据造假',
  '踏实':'' , 'li派':'站队李派', 'wang派':'站队王派', '告密':'四处告密',
  '驻村派':'扎根基层', '驻逃兵':'逃避基层', '清廉':'守住底线', '黑中介':'和稀泥',
  '举报':'敢于举报', '活跃':'积极活动', '成人之美':'成人之美', '走关系':'走门路',
  '抗洪英雄':'抗洪一线', '抗洪逃兵':'临阵退缩', '环保卫士':'环保底线',
  '污染企业主':'引进污染', '掮客':'充当掮客', '暧昧':'态度暧昧', '利益绑定':'利益绑定',
  '贤内助':'娶贤内助', '政治联姻':'政治联姻', '脚踩两船':'感情不专',
  '举报上级':'举报上级', '硬骨头':'坚持原则', '自保':'明哲保身', '同流':'同流合污',
  '安全卫士':'安全至上', '纵容':'纵容隐患', '黑心':'掩盖事故',
  '群众贴心人':'心系群众', '花钱消灾':'花钱买安', '截访':'截访压制',
  '毁证':'销毁证据', '立功':'检举立功', '暗箭':'暗箭伤人', '激进':'激进冒进',
  '民本':'以民为本', '站队':'紧跟领导', '清官':'两袖清风', '灰色':'灰色收入',
  '贪婪':'来者不拒', '得罪同事':'压缩开支', '豆腐渣':'偷工减料', '不喝':'拒酒',
  '讲政治':'突出政治', '贿选':'送礼拉票', '精准':'精准扶贫', '廉洁':'廉洁自律',
  '擦边':'打擦边球', '以权谋私':'以权谋私', '担当':'敢于担当', '维稳':'维稳优先',
  '甩锅':'推卸责任', '实绩':'凭实绩', '借力':'借力打力', '举报孙':'举报对手',
  '重金':'重金开路', '清白':'清白做人', '阳光':'阳光操作', '保护':'保护本土',
  '利益交换':'利益交换', '环保英雄':'环保铁腕', '应付':'敷衍应付', '平衡':'平衡兼顾',
  '打点':'打点关系', '直面':'直面矛盾', '强硬':'强硬处置', '诚信':'诚信为本',
  '注水':'数据注水', '攀附':'攀附领导', '破财':'破财消灾', '多疑':'疑心重',
  '正道':'正道直行', '造势':'舆论造势', '会做人':'善于交际', '高调':'高调立威',
  '贪墨':'侵吞公款', '民生':'保障民生', '程序':'程序正义', '减税':'减税纾困',
  '地产救市':'地产救市', '删帖':'删帖压热搜', '清者自清':'清者自清', '和解':'化敌为友',
  '反击':'以牙还牙', '组织':'依靠组织', '抢风头':'爱出风头', '招待':'违规接待',
  'chen派':'陈派成员', '独立':'自立门户', '改革':'锐意改革', '利益输送':'利益输送',
  '受贿':'收受贿赂', '勾连':'官商勾结', '上纲':'上纲上线', '协助':'协助调查',
  '抗疫':'抗疫一线', '特权':'滥用特权', '安排':'安排亲信', '硬气':'不畏威胁',
  '妥协':'妥协退让', '收':'收受回扣', '拒绝':'拒收回扣', '严谨':'严谨用人',
  '包庇':'包庇下属', '透明':'公开透明', '公关':'公关灭火', '公平':'唯才是举',
  '安插':'安插亲信', '孝子':'孝顺父母', '自信':'自信从容', '铺排':'铺张排场',
  '让路':'主动让路', '冲刺':'最后一搏', '余热':'发挥余热', '配合':'配合组织',
  '对抗':'暗中较劲', '平安':'平稳落地', '量力':'量力而行', '开明':'开明大度',
  '密友':'安插眼线', '精品':'打造精品', '快':'追求速度', '被动':'被动等待',
  '清廉从政':'清廉从政', '赞助':'接受赞助', '陪同':'违规陪同', '内部':'内幕交易',
  '帮忙':'乐于助人', '收礼':'收受礼品', '运作':'四处运作', '等待':'静待组织',
  '作为':'主动作为', '扎实':'' , '顶峰':'登顶巅峰', '享受':'享受成果', '传承':'' ,
  '治疗':'积极治疗', '硬撑':'带病硬撑', '毁灭':'毁灭证据', '律师':'聘请律师',
  '否认':'矢口否认', '说情':'托人说情', '抗拒':'对抗审查', '陪伴':'陪伴家人',
  '续做':'退而不休', '家庭':'回归家庭', '简朴':'简朴低调', '新政':'推行新政',
  '低调':'低调务实', '从简':'丧事从简', '反腐':'铁腕反腐', '制度建设':'制度建设',
  '实情':'实事求是', '突出':'突出政绩', '铁面':'铁面无私', '铁腕':'整肃队伍',
  '守':'' , '活动':'' , '游说':'游说拉票'
};

function renderAvatar(){
  $('player-name').textContent = state.name || '无名氏';
  $('player-phase').textContent = state.phase;
}

function renderQuestion(event){
  $('q-id').textContent = '#' + String(state.currentIdx + 1).padStart(3, '0');
  $('q-tag').textContent = event.phase;
  $('q-title').textContent = event.title;
  $('q-desc').textContent = event.desc;
  $('phase-label').textContent = state.phase;
  $('progress-text').textContent = `第 ${state.currentIdx + 1} 题 / 共 ${ALL_EVENTS.length} 题`;
  $('progress-fill').style.width = ((state.currentIdx + 1) / ALL_EVENTS.length * 100) + '%';

  const optionsEl = $('options');
  optionsEl.replaceChildren();
  const generation = runGeneration;
  const questionIndex = state.currentIdx;
  event.opts.forEach((opt, idx) => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'option';
    const wrap = document.createElement('span');
    wrap.className = 'option-text-wrap';
    wrap.append(
      textElement('span', 'option-key', String.fromCharCode(65 + idx)),
      textElement('span', 'option-text', opt.text)
    );
    btn.append(wrap);
    btn.onclick = () => {
      if(generation === runGeneration && questionIndex === state.currentIdx) chooseOption(opt);
    };
    optionsEl.appendChild(btn);
  });
  choiceLocked = false;
  if(activeScreen === 'game'){
    document.querySelector('.question-card').scrollIntoView({ block: 'start', behavior: 'instant' });
  }
}

function chooseOption(opt){
  if(!gameStarted || activeScreen !== 'game' || choiceLocked || state.dead || lifecyclePaused()) return;
  const event = getCurrentEvent();
  if(!event || !event.opts.includes(opt)) return;
  choiceLocked = true;
  choiceTrace.push(event.opts.indexOf(opt));
  $('options').querySelectorAll('button').forEach(button => { button.disabled = true; });
  // 1. 应用数值
  applyDelta(opt.delta);

  // 2. flag
  if(opt.flag){
    state.flags[opt.flag] = (state.flags[opt.flag] || 0) + 1;
  }

  // 3. 派生指标
  // 廉洁 ≈ 100 - 贪腐
  state.廉洁 = clamp(100 - state.贪腐 * 0.7 - state.财富 * 0.15, 0, 100);
  // 声望（来自事业和民心）
  state.声望 = Math.round((state.事业 * 0.5 + state.民心 * 0.3 + state.廉洁 * 0.2));
  state.phase = eventForPhase(state.currentIdx);

  pushLog(`选择了「${opt.text}」${opt.hint ? ' · ' + opt.hint : ''}`);

  // 4. 立即阈值检查
  const immediate = checkImmediateEnd();
  if(immediate){
    showEnding(immediate);
    return;
  }

  // 5. 刷新统计
  renderStats();
  renderAvatar();

  // 6. hint toast
  if(opt.hint) showHint(opt.hint);

  // 7. 下一题 / 结局
  const next = nextEvent();
  if(!next){
    // 全部走完 → 综合结算
    scheduleRunTask('advance', () => {
      const e = evaluateEnding();
      showEnding(e.id);
    }, 800);
    return;
  }

  // 推进到下一题（短延迟，让玩家看到效果）
  scheduleRunTask('advance', () => {
    renderQuestion(next);
  }, 350);
}

function eventForPhase(idx){
  const e = ALL_EVENTS[idx];
  return e ? e.phase : state.phase;
}

// ============== 提示 toast ==============
function showHint(text){
  const toast = $('hint-toast');
  toast.textContent = text;
  toast.classList.add('show');
  scheduleRunTask('toast', () => toast.classList.remove('show'), 1800);
}

// ============== 结局页 ==============
function showEnding(endingId){
  if(state.dead) return;
  choiceLocked = true;
  cancelRunTask('advance');
  // 找到结局
  const ending = ENDINGS.find(e => e.id === endingId) || evaluateEnding();
  state.ending = ending;
  state.dead = true;

  // 评级
  $('ending-grade').textContent = ending.grade;
  $('ending-grade').className = 'ending-grade ' + ending.grade.toLowerCase();
  $('ending-title').textContent = ending.title;
  $('ending-byline').textContent = `${state.name || '无名氏'} · ${GRADE_DESC[ending.grade] || ''}`;

  // 原版结局数据按原顺序展示，不注入 HTML。
  const statsBox = $('ending-stats');
  statsBox.replaceChildren();
  const addEndingStat = (label, value, journey = false) => {
    const item = document.createElement('div');
    item.className = 'ending-stat' + (journey ? ' ending-journey' : '');
    item.append(
      textElement('div', 'ending-stat-label', label),
      textElement('div', 'ending-stat-val', String(value))
    );
    statsBox.append(item);
  };
  ['贪腐','财富','民心','健康','人脉','事业'].forEach(k => addEndingStat(k, Math.round(state[k] || 0)));
  addEndingStat('走过题目', Math.min(state.currentIdx + 1, ALL_EVENTS.length), true);
  addEndingStat('关键抉择', Object.keys(state.flags).length, true);
  $('ending-text').textContent = ending.text;

  // 关键选择回顾
  const flagCount = {};
  Object.entries(state.flags).forEach(([k, v]) => {
    const label = FLAG_LABELS[k] || k;
    if(!label) return;
    flagCount[label] = (flagCount[label] || 0) + v;
  });
  const sortedFlags = Object.entries(flagCount)
    .sort((a, b) => b[1] - a[1])
    .filter(([k]) => k)
    .slice(0, 5)
    .map(([k, v]) => ({ label: k, count: v }));

  // 保留原版的关键选择汇总
  state.topFlags = sortedFlags;

  if(sortedFlags.length){
    const flags = document.createElement('div');
    flags.className = 'ending-flags';
    flags.append(textElement('div', 'flags-title', '你的关键抉择'));
    sortedFlags.forEach(f => flags.append(textElement('span', 'flag-chip', `${f.label} ×${f.count}`)));
    $('ending-text').append(flags);
  }

  // 得分仍使用原版算法。原生端自动提交出身与选项，服务器重算成绩。
  state.score = computeScore();
  addEndingStat('综合评分', state.score);
  prepareLeaderboardRun();

  // 跳到结局页
  scheduleRunTask('ending', () => showScreen('ending'), 600);
}

// ============== 出场设置 ==============
function renderOrigins(){
  const list = $('origin-list');
  list.replaceChildren();
  ORIGINS.forEach(o => {
    const item = document.createElement('button');
    item.type = 'button';
    item.className = 'origin-item' + (state.origin === o.id ? ' selected' : '');
    item.dataset.id = o.id;
    item.setAttribute('aria-pressed', String(state.origin === o.id));
    item.append(
      textElement('span', 'origin-name', o.name),
      textElement('span', 'origin-bonus', o.desc)
    );
    item.onclick = () => {
      if(gameStarted) return;
      list.querySelectorAll('.origin-item').forEach(x => {
        x.classList.remove('selected');
        x.setAttribute('aria-pressed', 'false');
      });
      item.classList.add('selected');
      item.setAttribute('aria-pressed', 'true');
      state.origin = o.id;
    };
    list.appendChild(item);
  });
}

function resetState(){
  invalidateRun();
  choiceTrace = [];
  didPrepareLeaderboard = false;
  state.name = LOCAL_PLAYER_NAME;
  state.origin = 'peasant';
  state.贪腐 = 0; state.财富 = 0; state.民心 = 50;
  state.健康 = 90; state.人脉 = 30; state.事业 = 0;
  state.廉洁 = 70; state.声望 = 0;
  state.currentIdx = 0; state.totalAnswered = 0;
  state.events = []; state.flags = {}; state.log = [];
  state.phase = '试用期'; state.dead = false; state.ending = null;
  state.topFlags = []; state.score = 0;
}

/* =========================================
   本地匿名模式：不读取或同步任何平台身份
   ========================================= */
const DISCLAIMER_SECONDS = 5;

function initDisclaimer(){
  const mask = $('disclaimer');
  const btn = $('btn-accept');
  const countEl = $('disclaimer-count');
  let left = DISCLAIMER_SECONDS;
  btn.disabled = true;
  const tick = () => {
    left--;
    if(left > 0){
      countEl.textContent = left;
      scheduleRunTask('disclaimer', tick, 1000);
      return;
    }
    btn.disabled = false;
    btn.textContent = '同意并开始体验';
  };
  scheduleRunTask('disclaimer', tick, 1000);
  $('screen-intro').inert = true;
  btn.onclick = () => {
    if(btn.disabled) return;
    disclaimerAccepted = true;
    cancelRunTask('disclaimer');
    mask.remove();
    $('screen-intro').inert = false;
    renderIdentity();
    $('btn-start').focus({ preventScroll: true });
  };
}

function renderIdentity(){
  $('account-name').textContent = LOCAL_PLAYER_NAME;
  $('account-sub').textContent = '完成游戏自动上榜 · 每人保留最高成绩';
  $('btn-start').disabled = !disclaimerAccepted;
}

function startGame(){
  const btn = $('btn-start');
  if(!disclaimerAccepted || btn.disabled || gameStarted || activeScreen !== 'intro') return;
  const selectedOrigin = state.origin;
  resetState();
  state.origin = selectedOrigin;
  state.name = LOCAL_PLAYER_NAME;
  gameStarted = true;
  btn.disabled = true;
  const origin = ORIGINS.find(o => o.id === state.origin) || ORIGINS[0];
  applyDelta(origin.bonus);
  state.phase = ALL_EVENTS[0].phase;
  renderStats();
  renderAvatar();
  renderQuestion(ALL_EVENTS[0]);
  showScreen('game');
}

// ============== 综合得分（排行榜用）==============
const GRADE_BASE = { S: 10000, A: 8000, B: 6000, C: 4000, D: 2000, F: 500 };

function computeScore(){
  const grade = (state.ending && state.ending.grade) || 'C';
  const base = GRADE_BASE[grade] !== undefined ? GRADE_BASE[grade] : 0;
  const detail = Math.round(
    (state.事业 || 0) * 20 +
    (state.民心 || 0) * 10 +
    (state.财富 || 0) * 5 +
    (state.健康 || 0) * 3 +
    (state.人脉 || 0) * 2 -
    (state.贪腐 || 0) * 30
  );
  return Math.max(-16777216, Math.min(16777215, base + detail));
}

// Only the final, bounded route crosses into the owned native host. Native
// code attaches its own rules version and authenticated session; the server
// must replay these untrusted indexes rather than trust a client-side score.
function prepareLeaderboardRun(){
  if(!state.dead || didPrepareLeaderboard || choiceTrace.length < 1 || choiceTrace.length > ALL_EVENTS.length) return;
  if(!ORIGINS.some(origin => origin.id === state.origin)) return;
  if(!choiceTrace.every(index => Number.isInteger(index) && index >= 0 && index < 4)) return;
  didPrepareLeaderboard = true;
  try {
    window.webkit?.messageHandlers?.gameLeaderboard?.postMessage({
      origin: state.origin,
      choices: choiceTrace.slice()
    });
  } catch {
    // An unavailable host cannot affect offline play or the original ending.
  }
}

// ============== 本地重开与绑定 ==============
function returnToIntro(){
  resetState();
  renderOrigins();
  renderIdentity();
  showScreen('intro');
}

function closeRestart(){
  restartOpen = false;
  $('restart-dialog').close();
  resumeRunTasks();
}

document.addEventListener('visibilitychange', () => {
  if(document.hidden) pauseRunTasks();
  else resumeRunTasks();
});
window.addEventListener('pagehide', () => {
  pageHidden = true;
  pauseRunTasks();
});
window.addEventListener('pageshow', () => {
  pageHidden = false;
  resumeRunTasks();
});

document.addEventListener('DOMContentLoaded', () => {
  resetState();
  renderOrigins();
  renderIdentity();
  initDisclaimer();
  $('btn-start').onclick = startGame;
  $('btn-restart').onclick = () => {
    if(restartOpen) return;
    restartOpen = true;
    pauseRunTasks();
    $('restart-dialog').showModal();
  };
  $('btn-cancel-restart').onclick = closeRestart;
  $('restart-dialog').addEventListener('cancel', event => {
    event.preventDefault();
    closeRestart();
  });
  $('btn-confirm-restart').onclick = () => {
    restartOpen = false;
    $('restart-dialog').close();
    returnToIntro();
  };
  $('btn-play-again').onclick = returnToIntro;
});
