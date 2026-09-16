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
  optionsEl.innerHTML = '';
  event.opts.forEach((opt, idx) => {
    const btn = document.createElement('button');
    btn.className = 'option';
    btn.innerHTML = `
      <div class="option-text-wrap">
        <span class="option-key">${String.fromCharCode(65 + idx)}</span>
        <span class="option-text">${opt.text}</span>
      </div>
    `;
    btn.onclick = () => chooseOption(opt);
    optionsEl.appendChild(btn);
  });
}

function chooseOption(opt){
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
    setTimeout(() => {
      const e = evaluateEnding();
      showEnding(e.id);
    }, 800);
    return;
  }

  // 推进到下一题（短延迟，让玩家看到效果）
  setTimeout(() => {
    renderQuestion(next);
  }, 350);
}

function eventForPhase(idx){
  const e = ALL_EVENTS[idx];
  return e ? e.phase : state.phase;
}

// ============== 提示 toast ==============
let toastTimer = null;
function showHint(text){
  const toast = $('hint-toast');
  toast.textContent = text;
  toast.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.remove('show'), 1800);
}

// ============== 结局页 ==============
function showEnding(endingId){
  // 找到结局
  const ending = ENDINGS.find(e => e.id === endingId) || evaluateEnding();
  state.ending = ending;
  state.dead = true;

  // 评级
  $('ending-grade').textContent = ending.grade;
  $('ending-grade').className = 'ending-grade ' + ending.grade.toLowerCase();
  $('ending-title').textContent = ending.title;
  $('ending-byline').textContent = `${state.name || '无名氏'} · ${GRADE_DESC[ending.grade] || ''}`;

  // 6 维数值
  const statsHtml = ['贪腐','财富','民心','健康','人脉','事业'].map(k => {
    return `<div class="ending-stat">
      <div class="ending-stat-label">${k}</div>
      <div class="ending-stat-val">${Math.round(state[k] || 0)}</div>
    </div>`;
  }).join('');

  // 旅程信息
  const journeyHtml = `
    <div class="ending-stat ending-journey">
      <div class="ending-stat-label">走过题目</div>
      <div class="ending-stat-val">${Math.min(state.currentIdx + 1, ALL_EVENTS.length)}</div>
    </div>
    <div class="ending-stat ending-journey">
      <div class="ending-stat-label">关键抉择</div>
      <div class="ending-stat-val">${Object.keys(state.flags).length}</div>
    </div>
  `;
  $('ending-stats').innerHTML = statsHtml + journeyHtml;

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

  // 保存供海报使用
  state.topFlags = sortedFlags;

  if(sortedFlags.length){
    const flagsHtml = sortedFlags.map(f => `<span class="flag-chip">${f.label} ×${f.count}</span>`).join('');
    $('ending-text').innerHTML = ending.text + `<div class="ending-flags"><div class="flags-title">你的关键抉择</div>${flagsHtml}</div>`;
  }

  // 初始化 Toy 能力（排行榜 / 关注 / 海报）
  initEndingSocial(ending);

  // 跳到结局页
  setTimeout(() => showScreen('ending'), 600);
}

// ============== 出场设置 ==============
function renderOrigins(){
  const list = $('origin-list');
  list.innerHTML = '';
  ORIGINS.forEach((o, idx) => {
    const item = document.createElement('div');
    item.className = 'origin-item' + (idx === 0 ? ' selected' : '');
    item.dataset.id = o.id;
    item.innerHTML = `
      <span class="origin-name">${o.name}</span>
      <span class="origin-bonus">${o.desc}</span>
    `;
    item.onclick = () => {
      list.querySelectorAll('.origin-item').forEach(x => x.classList.remove('selected'));
      item.classList.add('selected');
      state.origin = o.id;
    };
    list.appendChild(item);
  });
}

function resetState(){
  // 昵称来自 B 站账号，重开时保留
  state.name = (ToySDK.profile && ToySDK.profile.nickname) || state.name || '';
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
   toyid 全屏水印（所有页面常驻）
   ========================================= */
let watermarkToyId = null;

function buildWatermarkPattern(toyId){
  const mainText = toyId ? 'TOYID ' + toyId : 'TOYID 未获取';
  const subText = '仅供娱乐 · 违规传播将追责';
  const dpr = 2, w = 250, h = 150;
  const cv = document.createElement('canvas');
  cv.width = w * dpr; cv.height = h * dpr;
  const g = cv.getContext('2d');
  g.scale(dpr, dpr);
  g.translate(w / 2, h / 2);
  g.rotate(-20 * Math.PI / 180);
  g.textAlign = 'center';
  g.textBaseline = 'middle';
  g.font = '600 14px -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif';
  g.fillStyle = 'rgba(26,26,26,0.075)';
  g.fillText(mainText, 0, -10);
  g.font = '400 10px -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif';
  g.fillStyle = 'rgba(26,26,26,0.05)';
  g.fillText(subText, 0, 9);
  return cv.toDataURL('image/png');
}

function renderWatermark(toyId){
  const el = $('watermark');
  if(!el) return;
  if(toyId !== undefined) watermarkToyId = toyId || null;
  el.style.backgroundImage = `url(${buildWatermarkPattern(watermarkToyId)})`;
  el.style.backgroundSize = '250px 150px';
  el.style.backgroundRepeat = 'repeat';
  el.classList.add('show');
}

/* =========================================
   首次进入：强制 5 秒免责声明
   ========================================= */
const DISCLAIMER_KEY = 'huanghai_disclaimer_v1';
const DISCLAIMER_SECONDS = 5;

function initDisclaimer(){
  const mask = $('disclaimer');
  if(!mask) return Promise.resolve();
  let seen = false;
  try{ seen = localStorage.getItem(DISCLAIMER_KEY) === '1'; }catch(e){}
  if(seen){ mask.remove(); return Promise.resolve(); }

  const btn = $('btn-accept');
  const countEl = $('disclaimer-count');
  btn.disabled = true;

  return new Promise((resolve) => {
    let left = DISCLAIMER_SECONDS;
    const timer = setInterval(() => {
      left--;
      if(left > 0){
        countEl.textContent = left;
        return;
      }
      clearInterval(timer);
      btn.disabled = false;
      btn.innerHTML = '我已阅读并同意';
    }, 1000);

    btn.onclick = () => {
      if(btn.disabled) return;
      clearInterval(timer);
      try{ localStorage.setItem(DISCLAIMER_KEY, '1'); }catch(e){}
      mask.classList.add('hide');
      setTimeout(() => mask.remove(), 320);
      resolve();
    };
  });
}

/* =========================================
   身份：B 站昵称 + toyid（禁止自填）
   ========================================= */
function renderIdentity(){
  const p = ToySDK.profile;
  const nameEl = $('account-name');
  const subEl  = $('account-sub');
  const btnStart = $('btn-start');
  const retry = $('btn-retry-profile');
  const tip = $('start-tip');

  if(p && p.nickname){
    nameEl.textContent = p.nickname;
    nameEl.classList.remove('loading');
    subEl.textContent = 'B 站昵称已同步 · TOYID ' + (ToySDK.toyId || '—');
    retry.hidden = true;
    btnStart.disabled = false;
    tip.hidden = true;
    state.name = p.nickname;
  } else {
    nameEl.textContent = '未能获取 B 站身份';
    nameEl.classList.add('loading');
    subEl.textContent = ToySDK.hasSDK()
      ? '请点击右侧重试，授权后即可开始'
      : '请在 B站 App 内打开本游戏';
    retry.hidden = false;
    btnStart.disabled = true;
    tip.hidden = true;
  }
}

async function initIdentity(){
  const ok = await ToySDK.init();
  if(ok){
    await ToySDK.loadProfile();
    await ToySDK.loadToyId();
  }
  renderIdentity();
  renderWatermark(ToySDK.toyId);
  const dt = $('disclaimer-toyid');
  if(dt) dt.textContent = ToySDK.toyId || '未获取';
  return ok;
}

async function startGame(){
  const btn = $('btn-start');
  if(btn.disabled) return;

  // 用户手势内再取一次昵称（部分环境需手势才授权）
  if(!ToySDK.profile){
    btn.disabled = true;
    btn.textContent = '获取身份中…';
    await ToySDK.loadProfile();
    await ToySDK.loadToyId();
    renderIdentity();
    renderWatermark(ToySDK.toyId);
    const dt = $('disclaimer-toyid');
    if(dt) dt.textContent = ToySDK.toyId || '未获取';
    btn.textContent = '踏入仕途 →';
  }

  if(!ToySDK.profile){
    btn.disabled = true;
    alert('需要先获取 B 站昵称才能开始游戏，请点击重试。');
    return;
  }

  state.name = ToySDK.profile.nickname;
  // 应用出身加成
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

// ============== 结局页社交功能 ==============
let posterDataURL = null;
let myRankInfo = null;

async function initEndingSocial(ending){
  // 先算好分数
  state.score = computeScore();

  // 初始化 SDK
  const ok = await ToySDK.init();
  $('author-name').textContent = ToySDK.authorName;

  if(!ok){
    // SDK 不可用（本地 / 外部浏览器）：仍可生成海报，但榜单不可用
    $('follow-bar').style.display = 'none';
    $('btn-submit-score').style.display = 'none';
    $('rank-list').innerHTML = '<div class="rank-empty">排行榜需在 B站 内打开</div>';
    return;
  }

  // 检查关注状态 + 拉取榜单（并行，减少等待）
  await Promise.all([
    refreshFollowState(),
    renderRankList(),
    renderMyRank()
  ]);

  // 从 B站空间返回时，重新检查关注状态
  document.addEventListener('visibilitychange', async () => {
    if(document.visibilityState === 'visible' && !document.getElementById('screen-ending').classList.contains('active')) return;
    if(document.visibilityState === 'visible'){
      await refreshFollowState();
    }
  });
}

async function refreshFollowState(){
  const following = await ToySDK.checkFollow();
  ToySDK.isFollowing = following;
  const bar = $('follow-bar');
  const btn = $('btn-follow');
  if(following){
    bar.classList.add('followed');
    $('follow-title').textContent = '已关注，感谢支持！';
    btn.textContent = '已关注';
    btn.disabled = true;
    $('btn-submit-score').disabled = false;
    $('btn-submit-score').textContent = '上传我的成绩';
    $('btn-generate-poster').disabled = false;
  } else {
    bar.classList.remove('followed');
    $('follow-title').textContent = '关注 UP 主后即可上榜 & 保存海报';
    btn.textContent = '关注';
    btn.disabled = false;
    $('btn-submit-score').disabled = true;
    $('btn-submit-score').textContent = '关注后上传成绩';
    $('btn-generate-poster').disabled = true;
  }
}

async function renderRankList(){
  const list = await ToySDK.getRankList(20);
  const box = $('rank-list');
  if(!list.length){
    box.innerHTML = '<div class="rank-empty">暂无成绩，快来抢占榜首</div>';
    return;
  }
  // 判断"我"：优先昵称匹配，其次名次匹配
  const myName = (ToySDK.profile && ToySDK.profile.nickname) || '';
  box.innerHTML = list.map((it, i) => {
    const medal = i === 0 ? '🥇' : i === 1 ? '🥈' : i === 2 ? '🥉' : '';
    let isMe = false;
    if(myName && it.nickname === myName) isMe = true;
    else if(!myName && myRankInfo && myRankInfo.ranked && myRankInfo.rank === it.rank) isMe = true;
    return `<div class="rank-item${isMe ? ' me' : ''}">
      <span class="rank-no">${medal || it.rank}</span>
      <span class="rank-name">${escapeHtml(it.nickname || '匿名官员')}</span>
      <span class="rank-score">${it.score}</span>
    </div>`;
  }).join('');
}

async function renderMyRank(){
  const mine = await ToySDK.getMyRank();
  const box = $('my-rank');
  if(mine && mine.ranked){
    myRankInfo = mine;
    box.innerHTML = `<div class="my-rank-inner">我的排名 <b>第 ${mine.rank} 名</b> · 得分 <b>${mine.score}</b></div>`;
    box.style.display = 'block';
  } else {
    myRankInfo = null;
    box.style.display = 'none';
  }
}

function escapeHtml(s){
  return String(s).replace(/[&<>"']/g, c => ({
    '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;'
  }[c]));
}

// ---------- 关注 ----------
async function handleFollow(){
  const ok = await ToySDK.goFollow();
  if(!ok){
    alert('请在 B站 App 内打开以关注 UP 主');
  }
}

// ---------- 上传成绩 ----------
async function handleSubmitScore(){
  if(!ToySDK.isFollowing){
    await handleFollow();
    return;
  }
  const btn = $('btn-submit-score');
  btn.disabled = true;
  btn.textContent = '上传中…';
  try{
    // 提交前确保有昵称（会触发一次用户资料确认，需用户手势内）
    await ToySDK.loadProfile();
    const score = state.score || computeScore();
    await ToySDK.submitScore(score);
    // 保存本地最佳
    await ToySDK.saveBest({
      score,
      grade: state.ending.grade,
      title: state.ending.title,
      ts: Date.now()
    });
    await renderMyRank();
    await renderRankList();
    btn.textContent = '已上榜 ✓';
    setTimeout(() => {
      btn.textContent = '更新成绩';
      btn.disabled = false;
    }, 2000);
  }catch(e){
    btn.textContent = '上传失败，重试';
    btn.disabled = false;
  }
}

// ---------- 海报 ----------
async function handleGeneratePoster(){
  if(!ToySDK.isFollowing){
    await handleFollow();
    return;
  }
  const btn = $('btn-generate-poster');
  btn.disabled = true;
  btn.textContent = '生成中…';
  try{
    if(!ToySDK.profile) await ToySDK.loadProfile();
    const qr = await ToySDK.getQrCode(240);

    posterDataURL = await PosterMaker.generate({
      name: (ToySDK.profile && ToySDK.profile.nickname) || state.name || '无名氏',
      title: state.ending.title,
      grade: state.ending.grade,
      text: state.ending.text,
      stats: {
        贪腐: state.贪腐, 财富: state.财富, 民心: state.民心,
        健康: state.健康, 人脉: state.人脉, 事业: state.事业
      },
      score: state.score || computeScore(),
      rank: myRankInfo && myRankInfo.ranked ? myRankInfo.rank : null,
      qrBase64: qr,
      flagsTop: state.topFlags || [],
      author: ToySDK.authorName,
      toyId: ToySDK.toyId,
      answered: Math.min(state.currentIdx + 1, ALL_EVENTS.length)
    });

    $('poster-img').src = posterDataURL;
    $('poster-modal').classList.add('show');
    const canSave = await window.toy.isSupport('saveImageToAlbum').catch(() => false);
    $('poster-tip').textContent = canSave ? '' : '当前环境将直接下载图片';
    $('btn-save-poster').textContent = canSave ? '保存到相册' : '下载海报';
  }catch(e){
    alert('海报生成失败，请重试');
  }
  btn.disabled = false;
  btn.textContent = '生成成绩海报';
}

// ---------- 保存海报 ----------
async function handleSavePoster(){
  if(!posterDataURL) return;
  const btn = $('btn-save-poster');
  btn.disabled = true;
  btn.textContent = '处理中…';
  try{
    const saved = await ToySDK.saveImage(posterDataURL);
    if(!saved){
      // Web 端：用 <a download>
      const a = document.createElement('a');
      a.href = posterDataURL;
      a.download = `宦海浮沉录-${state.ending.grade}级-${Date.now()}.png`;
      document.body.appendChild(a);
      a.click();
      a.remove();
    }
    btn.textContent = '已保存 ✓';
  }catch(e){
    // 兜底也走下载
    const a = document.createElement('a');
    a.href = posterDataURL;
    a.download = `宦海浮沉录-${state.ending.grade}级.png`;
    document.body.appendChild(a);
    a.click();
    a.remove();
    btn.textContent = '已下载 ✓';
  }
  setTimeout(() => {
    btn.disabled = false;
    btn.textContent = '保存海报';
  }, 1800);
}

// ============== 绑定 ==============
document.addEventListener('DOMContentLoaded', async () => {
  // 出场
  renderOrigins();

  // 1. 立即铺水印（拿到 toyid 后再刷新内容）
  renderWatermark(null);

  // 2. 强制 5 秒免责声明（与身份获取同时进行，不额外占用时间）
  const disclaimerPromise = initDisclaimer();

  // 3. 获取 B 站身份 + toyid
  const identityPromise = initIdentity();

  await Promise.all([disclaimerPromise, identityPromise]);
  renderWatermark(ToySDK.toyId);

  $('btn-start').onclick = startGame;
  $('btn-retry-profile').onclick = async () => {
    const btn = $('btn-retry-profile');
    btn.disabled = true;
    btn.textContent = '获取中…';
    ToySDK.profile = null;      // 强制重新拉取
    ToySDK.toyId = null;
    await initIdentity();
    btn.disabled = false;
    btn.textContent = '重试';
  };

  // 顶部重新开始
  $('btn-restart').onclick = () => {
    if(confirm('确定要重新开始吗？进度会清空。')){
      resetState();
      showScreen('intro');
    }
  };

  // 结局页按钮
  $('btn-play-again').onclick = () => {
    resetState();
    showScreen('intro');
  };

  // 社交功能
  $('btn-follow').onclick = handleFollow;
  $('btn-submit-score').onclick = handleSubmitScore;
  $('btn-generate-poster').onclick = handleGeneratePoster;
  $('btn-save-poster').onclick = handleSavePoster;
  $('poster-close').onclick = () => $('poster-modal').classList.remove('show');
  $('poster-modal').onclick = (e) => {
    if(e.target.id === 'poster-modal') $('poster-modal').classList.remove('show');
  };
});