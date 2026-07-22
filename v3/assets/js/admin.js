// 코스모스 출석 v3 — 관리자 페이지 (오늘 현황 · 통계 · 명단 · 설정)
import {
  sb, setAuthStorageKey, logout, currentUser, mustChangePin, changePin,
  isStaff, isAdmin, allStudents, allSessions, activeSessions, attendanceInRange, setStudentActive,
} from './sb.js';
import { ADMIN_EMAIL, PROGRAMS } from './config.js';

// ★ 관리자는 별도 저장키 — 같은 브라우저에서 학생/교사 세션과 공존 (HANDOFF §3)
setAuthStorageKey('cosmos_v3_admin');

const $ = (id) => document.getElementById(id);
const REDUCE = matchMedia('(prefers-reduced-motion: reduce)').matches;
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const VIEWS = ['view-loading', 'view-login', 'view-pin', 'view-main'];
function show(id) {
  for (const v of VIEWS) { const el = $(v); if (!el) continue; el.classList.toggle('on', v === id); if (v !== id) el.classList.remove('enter'); }
  const t = $(id); if (t && id !== 'view-loading' && !REDUCE) { void t.offsetWidth; t.classList.add('enter'); }
}
let toastTimer;
function toast(msg, kind) {
  const t = $('toast'); t.textContent = msg; t.className = 'toast on' + (kind ? ' ' + kind : '');
  clearTimeout(toastTimer); toastTimer = setTimeout(() => { t.className = 'toast'; }, 3200);
}

// ── 날짜/표기 헬퍼 (관리자 PC 로컬 = KST 기준) ──
const pad2 = (n) => String(n).padStart(2, '0');
const localDate = (d = new Date()) => `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
const daysAgo = (n) => { const d = new Date(); d.setDate(d.getDate() - n); return localDate(d); };
const monthStart = () => { const d = new Date(); return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-01`; };
const fmtTime = (v) => { if (!v) return ''; const m = String(v).match(/(\d{2}):(\d{2})/); return m ? `${m[1]}:${m[2]}` : String(v); };
// timestamptz(UTC 직렬화) → KST 고정 표시. 브라우저 로컬 TZ에 의존하면 비KST 환경에서 어긋난다.
const kstTime = (ts, withSec) => {
  if (!ts) return '';
  const o = { timeZone: 'Asia/Seoul', hour12: false, hour: '2-digit', minute: '2-digit' };
  if (withSec) o.second = '2-digit';
  try { return new Date(ts).toLocaleTimeString('en-GB', o); } catch (_) { return String(ts); }
};
const fmtMD = (iso) => { const p = String(iso).split('-'); return p.length === 3 ? `${+p[1]}.${+p[2]}` : iso; };
const isMissing = (r) => r.상태 === '퇴실미확인';
const isEarly = (r) => r.상태 === '조퇴';
const isAbsent = (r) => r.상태 === '결석';

// RPC 미배포(마이그레이션 전) 판별
const isRpcMissing = (e) => e && (e.code === 'PGRST202' || /Could not find the function/i.test(e.message || ''));

// ── 부팅 / 게이트 ──
async function gateOk(user) {
  if (!user) return false;
  if ((user.email || '').toLowerCase() !== ADMIN_EMAIL.toLowerCase()) return false;
  if (!(await isStaff())) return false;
  const adm = await isAdmin();       // true/false = is_admin() 판정, null = 함수 미배포 → 이메일+staff로 폴백
  return adm !== false;
}

async function boot() {
  show('view-loading');
  let user = null;
  try { user = await currentUser(); } catch (_) { /* 네트워크 등 — 로그인으로 */ }
  if (!user) { show('view-login'); return; }
  if (!(await gateOk(user))) { await logout(); toast('관리자 계정이 아니에요', 'err'); show('view-login'); return; }
  if (mustChangePin(user)) { show('view-pin'); return; }
  enterMain();
}

async function doLogin() {
  const pin = $('a-pin').value.trim();
  const btn = $('a-login-btn');
  if (pin.length < 4) { toast('PIN을 입력해주세요'); return; }
  btn.disabled = true; btn.textContent = '확인 중…';
  try {
    const { error } = await sb().auth.signInWithPassword({ email: ADMIN_EMAIL, password: pin });
    if (error) throw error;
    const user = await currentUser();
    if (!(await gateOk(user))) { await logout(); toast('관리자 권한이 없는 계정이에요', 'err'); return; }
    if (mustChangePin(user)) { show('view-pin'); return; }
    enterMain();
  } catch (e) {
    toast(/Invalid login/i.test(e.message || '') ? 'PIN이 올바르지 않아요' : ('로그인 실패: ' + (e.message || '오류')), 'err');
  } finally {
    btn.disabled = false; btn.textContent = '로그인'; $('a-pin').value = '';
  }
}

async function doFirstPinChange() {
  const p1 = $('a-pin-new').value.trim(), p2 = $('a-pin-new2').value.trim();
  const btn = $('a-pin-btn');
  // 관리자 = 최고권한 단일 계정 — 4자리(1만 조합)는 무차별 대입에 취약, 6자리 이상 강제
  if (!/^\d{6,12}$/.test(p1)) { toast('관리자 PIN은 숫자 6~12자리로 해주세요'); return; }
  if (p1 !== p2) { toast('두 PIN이 일치하지 않아요'); return; }
  btn.disabled = true; btn.textContent = '저장 중…';
  try { await changePin(p1); toast('PIN이 설정됐어요', 'ok'); enterMain(); }
  catch (e) { toast('변경 실패: ' + (e.message || '오류'), 'err'); }
  finally { btn.disabled = false; btn.textContent = 'PIN 설정하기'; }
}

// ── 탭 ──
const PANES = ['today', 'stats', 'roster', 'settings'];
let currentTab = 'today';
const loadedOnce = new Set();

function switchTab(name) {
  currentTab = name;
  document.querySelectorAll('.tab').forEach((b) => b.classList.toggle('on', b.dataset.tab === name));
  for (const p of PANES) $('pane-' + p).classList.toggle('on', p === name);
  if (name === 'today') startTodayPolling(); else stopTodayPolling();
  if (!loadedOnce.has(name)) {
    loadedOnce.add(name);
    if (name === 'stats') loadStats();
    if (name === 'roster') loadRoster();
    if (name === 'settings') runDiag();
  }
}

function enterMain() {
  show('view-main');
  populateProgramSelects();
  loadedOnce.add('today');
  switchTab('today');
  loadToday();
}

function populateProgramSelects() {
  for (const id of ['st-program', 'ro-program']) {
    const sel = $(id);
    if (sel.options.length > 1) continue;
    for (const p of PROGRAMS) { const o = document.createElement('option'); o.value = p; o.textContent = p; sel.appendChild(o); }
  }
}

// ══════════════ 오늘 ══════════════
let todayTimer = null;
let sessionsReadable = true;   // sessions SELECT 정책 미적용 환경 폴백

function startTodayPolling() { stopTodayPolling(); todayTimer = setInterval(() => { if (!document.hidden) loadToday(); }, 15000); }
function stopTodayPolling() { if (todayTimer) { clearInterval(todayTimer); todayTimer = null; } }

async function loadToday() {
  const today = localDate();
  // ⚠️ RLS는 정책이 없으면 에러가 아니라 '빈 결과'를 준다 — 활성 0개일 때는 전체 행수로 정책 유무를 가늠
  let sess = [], sessProblem = null;
  try {
    sess = await activeSessions();
    sessionsReadable = true;
    if (!sess.length) {
      const { count } = await sb().from('sessions').select('*', { count: 'exact', head: true });
      if (!count) sessProblem = 'empty';   // 세션 테이블이 0행으로 보임 = 읽기 정책 미적용 가능성
    }
  } catch (_) { sessionsReadable = false; sessProblem = 'error'; }
  let rows = [];
  try { rows = await attendanceInRange(today, today); }
  catch (e) { toast('오늘 기록을 불러오지 못했어요: ' + (e.message || '오류'), 'err'); return; }

  const banner = $('today-banner');
  if (sessProblem) {
    banner.textContent = sessProblem === 'error'
      ? '세션 목록을 읽지 못했어요 — docs/w3_migration.sql 적용 후 새로고침하면 활성 세션·재실 인원이 표시돼요.'
      : '세션 테이블이 0행으로 보여요 — 읽기 정책 미적용일 수 있어요 (docs/w3_migration.sql). 실제로 세션이 없는 것일 수도 있어요.';
    banner.classList.remove('hidden');
  } else banner.classList.add('hidden');

  const att = rows.filter((r) => !isAbsent(r));
  $('td-att').textContent = att.length;
  $('td-att-sub').textContent = rows.length - att.length > 0 ? `결석 기록 ${rows.length - att.length}건 별도` : '';
  $('td-out').textContent = att.filter((r) => r.퇴실시각).length;
  $('td-miss').textContent = att.filter(isMissing).length;

  // 활성 세션 카드 + 재실
  const grid = $('td-sessions');
  if (!sessionsReadable) { grid.innerHTML = ''; $('td-in').textContent = '–'; }
  else if (!sess.length) { grid.innerHTML = '<div class="card empty-note" style="grid-column:1/-1">지금 진행 중인 세션이 없어요.</div>'; $('td-in').textContent = '0'; }
  else {
    // v2 sibling 세션(같은 세션id·다른 장소로 복수 행) dedup — 행 단위로 그리면 카드·재실이 이중 집계된다
    const bySid = new Map();
    for (const s of sess) {
      const k = String(s.세션id);
      if (!bySid.has(k)) bySid.set(k, { ...s, 장소들: [s.장소].filter(Boolean) });
      else { const g = bySid.get(k); if (s.장소 && !g.장소들.includes(s.장소)) g.장소들.push(s.장소); }
    }
    const stayIds = new Set();   // 재실 '명'은 학번 고유 계수 (두 세션에 걸친 미퇴실 중복 방지)
    grid.innerHTML = [...bySid.values()].map((s) => {
      const inSess = att.filter((r) => String(r.세션id) === String(s.세션id));
      const stayRows = inSess.filter((r) => !r.퇴실시각 && r.상태 === '출석');
      stayRows.forEach((r) => stayIds.add(String(r.학번)));
      const exitValid = s.퇴실코드 && s.퇴실코드만료 && new Date(s.퇴실코드만료).getTime() > Date.now();
      return `<div class="sess">
        <div class="m"><b>${esc(s.프로그램)}</b> · ${esc(s.장소들.join(' · '))}${s.교사 ? ' · ' + esc(s.교사) : ''}</div>
        <div class="codes">
          <div class="cd"><div class="l">입실 코드</div><div class="c">${esc(s.입실코드 || '—')}</div></div>
          <div class="cd"><div class="l">퇴실 코드</div><div class="c${exitValid ? '' : ' exp'}">${esc(s.퇴실코드 || '—')}</div></div>
        </div>
        <div class="cnt">입실 <b>${inSess.length}</b> · 재실 <b>${stayRows.length}</b> · 퇴실 <b>${inSess.filter((r) => r.퇴실시각).length}</b></div>
      </div>`;
    }).join('');
    $('td-in').textContent = stayIds.size;
  }

  // 오늘 기록 테이블 (최근순)
  const CAP = 200;
  const list = rows.slice().sort((a, b) => String(b.원래시각 || '').localeCompare(String(a.원래시각 || '')));
  $('td-list-note').textContent = rows.length ? (rows.length > CAP ? `총 ${rows.length}건 중 최근 ${CAP}건` : `총 ${rows.length}건`) : '';
  $('td-rows').innerHTML = list.length ? list.slice(0, CAP).map((r) => `<tr>
      <td class="num">${fmtTime(r.원래시각)}</td>
      <td class="num">${esc(r.학번)}</td>
      <td>${esc(r.이름)}</td>
      <td class="dim">${esc(r.프로그램)}</td>
      <td class="dim">${esc(r.장소)}</td>
      <td class="num">${r.퇴실시각 ? kstTime(r.퇴실시각) : '<span class="dim">—</span>'}</td>
      <td>${statusBadge(r)}</td>
    </tr>`).join('') : '<tr class="empty"><td colspan="7">오늘 출석 기록이 아직 없어요.</td></tr>';
}

function statusBadge(r) {
  if (isAbsent(r)) return '<span class="bdg err">결석</span>';
  if (isMissing(r)) return '<span class="bdg warn">퇴실미확인</span>';
  if (isEarly(r)) return '<span class="bdg">조퇴</span>';
  const late = r.사후여부 ? ' <span class="bdg">사후</span>' : '';
  return '<span class="bdg ok">출석</span>' + late;
}

// ══════════════ 통계 ══════════════
let statRows = [];      // 현재 조회 결과 (CSV용)
let statRange = null;

function resolveRange() {
  const v = $('st-range').value;
  if (v === '7') return { from: daysAgo(6), to: localDate() };
  if (v === '30') return { from: daysAgo(29), to: localDate() };
  if (v === 'month') return { from: monthStart(), to: localDate() };
  if (v === 'all') return { from: null, to: null };
  const from = $('st-from').value || null, to = $('st-to').value || null;
  if (from && to && from > to) return null;
  return { from, to };
}

async function loadStats() {
  const range = resolveRange();
  if (!range) { toast('시작일이 종료일보다 늦어요'); return; }
  const program = $('st-program').value || null;
  const btn = $('st-load'); btn.disabled = true; btn.textContent = '불러오는 중…';
  try {
    const [rows, sessions] = await Promise.all([
      attendanceInRange(range.from, range.to, program),
      allSessions().catch(() => []),          // 정책 미적용 시 v3 판별만 비활성
    ]);
    statRows = rows; statRange = range;
    renderStats(rows, sessions, range, program);
    $('st-csv').disabled = !rows.length;
    $('st-body').style.display = ''; $('st-hint').style.display = 'none';
  } catch (e) {
    toast('통계를 불러오지 못했어요: ' + (e.message || '오류'), 'err');
  } finally { btn.disabled = false; btn.textContent = '조회'; }
}

function renderStats(rows, sessions, range, program) {
  const att = rows.filter((r) => !isAbsent(r));
  const absent = rows.length - att.length;
  $('st-range-note').textContent =
    `${range.from || '처음'} ~ ${range.to || '오늘'}${program ? ' · ' + program : ''} · 총 ${rows.length.toLocaleString()}행`;
  $('st-att').textContent = att.length.toLocaleString();
  $('st-absent-sub').textContent = absent > 0 ? `결석 기록 ${absent.toLocaleString()}건 별도` : '';
  $('st-students').textContent = new Set(att.map((r) => String(r.학번))).size;
  $('st-sess').textContent = new Set(att.map((r) => String(r.세션id))).size;

  // 퇴실 체크(v3) — 입실코드가 발급된 세션의 행 + 퇴실 흔적(퇴실시각·퇴실방식·퇴실미확인·조퇴)이 있는 행.
  // 흔적 기반 이중 판별인 이유: sessions를 못 읽는 상황(정책 미적용·일시 오류)에서 세션 목록만 믿으면
  // 실데이터가 있는데도 '운영된 세션 없음'으로 오표시된다 — 데이터 자체가 v3 운영의 증거다.
  const sessionsOk = sessions.length > 0;
  const v3ids = new Set(sessions.filter((s) => s.입실코드).map((s) => String(s.세션id)));
  const v3rows = att.filter((r) =>
    v3ids.has(String(r.세션id)) || r.퇴실시각 || r.퇴실방식 || isMissing(r) || isEarly(r));
  const exitNote = $('st-exit-note');
  if (exitNote) {
    exitNote.textContent = sessionsOk
      ? '입실·퇴실 코드로 운영된 세션만 집계해요'
      : '세션 목록을 읽지 못했어요 — 진행 중 세션의 행은 누락될 수 있어요 (w3_migration.sql 확인)';
  }
  if (!v3rows.length) {
    $('st-exit-empty').textContent = sessionsOk
      ? '이 기간에는 퇴실 체크로 운영된 세션이 아직 없어요.'
      : '세션 목록을 읽지 못했고, 이 기간 퇴실 체크 기록도 없어요 — 정책 미적용이면 docs/w3_migration.sql 적용 후 다시 조회해주세요.';
    $('st-exit-empty').classList.remove('hidden'); $('st-exit-kpis').style.display = 'none';
  }
  else {
    $('st-exit-empty').classList.add('hidden'); $('st-exit-kpis').style.display = '';
    const out = v3rows.filter((r) => r.퇴실시각).length;
    const miss = v3rows.filter(isMissing).length;
    const early = v3rows.filter(isEarly).length;
    $('st-v3n').textContent = v3rows.length.toLocaleString();
    $('st-outrate').textContent = Math.round((out / v3rows.length) * 100);
    $('st-outrate-sub').textContent = `${out.toLocaleString()} / ${v3rows.length.toLocaleString()}건`;
    $('st-missn').textContent = miss.toLocaleString();
    $('st-early').textContent = early.toLocaleString();
  }

  renderChart(att, range);
  renderMissTable(att);
  renderStudentTable(att);
}

// ── 일별(62일 초과 시 주별) 추이 차트 ──
function renderChart(att, range) {
  const chart = $('st-chart'), xl = $('st-xlabels');
  if (!att.length) { chart.innerHTML = ''; xl.innerHTML = ''; $('st-ymax').textContent = ''; $('st-chart-note').textContent = ''; return; }
  const dates = att.map((r) => r.날짜).filter(Boolean);
  const from = range.from || dates.reduce((a, b) => (a < b ? a : b));
  const to = range.to || dates.reduce((a, b) => (a > b ? a : b));
  const dayN = Math.round((new Date(to + 'T00:00:00') - new Date(from + 'T00:00:00')) / 864e5) + 1;
  const weekly = dayN > 62;

  const keyOf = (iso) => {
    if (!weekly) return iso;
    const d = new Date(iso + 'T00:00:00');
    d.setDate(d.getDate() - ((d.getDay() + 6) % 7));   // 그 주 월요일
    return localDate(d);
  };
  const buckets = new Map();   // key → { att, miss }
  {
    const cur = new Date(from + 'T00:00:00');
    const end = new Date(to + 'T00:00:00');
    while (cur <= end) { const k = keyOf(localDate(cur)); if (!buckets.has(k)) buckets.set(k, { att: 0, miss: 0 }); cur.setDate(cur.getDate() + 1); }
  }
  for (const r of att) {
    const k = keyOf(r.날짜); if (!buckets.has(k)) buckets.set(k, { att: 0, miss: 0 });
    const b = buckets.get(k); b.att++; if (isMissing(r)) b.miss++;
  }
  const keys = [...buckets.keys()].sort();
  const max = Math.max(...keys.map((k) => buckets.get(k).att), 1);
  $('st-ymax').textContent = `최대 ${max}건`;
  $('st-chart-note').textContent = weekly ? '주별 합계 (월요일 시작)' : '일별 건수';

  chart.innerHTML = keys.map((k) => {
    const b = buckets.get(k);
    const attH = Math.round((Math.max(0, b.att - b.miss) / max) * 100);
    const missH = Math.round((b.miss / max) * 100);
    const label = `${weekly ? k + ' 주' : k} · 출석 ${b.att}건` + (b.miss ? ` · 퇴실미확인 ${b.miss}건` : '');
    return `<div class="col" data-tip="${esc(label)}" aria-label="${esc(label)}">
      ${b.miss ? `<div class="seg miss" style="height:${missH}%"></div>` : ''}
      <div class="seg att${b.miss ? '' : ' top'}" style="height:${attH}%"></div>
    </div>`;
  }).join('');

  const step = Math.max(1, Math.ceil(keys.length / 10));
  xl.innerHTML = keys.map((k, i) => `<span class="xl">${i % step === 0 ? fmtMD(k) : ''}</span>`).join('');
}

function renderMissTable(att) {
  const map = new Map();
  for (const r of att) {
    const k = String(r.학번);
    if (!map.has(k)) map.set(k, { hakbun: k, name: r.이름 || '', att: 0, miss: 0 });
    const m = map.get(k); m.att++; if (isMissing(r)) m.miss++;
  }
  const list = [...map.values()].filter((m) => m.miss > 0).sort((a, b) => b.miss - a.miss || b.att - a.att).slice(0, 30);
  $('st-miss-rows').innerHTML = list.length ? list.map((m, i) => `<tr${m.miss >= 2 ? ' style="font-weight:600"' : ''}>
      <td class="num dim">${i + 1}</td><td class="num">${esc(m.hakbun)}</td><td>${esc(m.name)}</td>
      <td class="num">${m.miss}회</td><td class="num dim">${m.att}회</td><td class="num">${Math.round((m.miss / m.att) * 100)}%</td>
    </tr>`).join('') : '<tr class="empty"><td colspan="6">이 기간 퇴실미확인 기록이 없어요.</td></tr>';
}

let stuAgg = [];
function renderStudentTable(att) {
  const map = new Map();
  for (const r of att) {
    const k = String(r.학번);
    if (!map.has(k)) map.set(k, { hakbun: k, name: r.이름 || '', att: 0, miss: 0, early: 0, last: '' });
    const m = map.get(k); m.att++; if (isMissing(r)) m.miss++; if (isEarly(r)) m.early++;
    if (r.날짜 > m.last) m.last = r.날짜;
  }
  stuAgg = [...map.values()].sort((a, b) => a.hakbun.localeCompare(b.hakbun));
  paintStudentTable();
}
function paintStudentTable() {
  const q = ($('st-search').value || '').trim().toLowerCase();
  const list = q ? stuAgg.filter((m) => m.hakbun.includes(q) || m.name.toLowerCase().includes(q)) : stuAgg;
  $('st-stu-rows').innerHTML = list.length ? list.map((m) => `<tr>
      <td class="num">${esc(m.hakbun)}</td><td>${esc(m.name)}</td><td class="num">${m.att}</td>
      <td class="num${m.miss ? '' : ' dim'}">${m.miss || '·'}</td><td class="num${m.early ? '' : ' dim'}">${m.early || '·'}</td>
      <td class="num dim">${esc(m.last)}</td>
    </tr>`).join('') : '<tr class="empty"><td colspan="6">해당하는 학생이 없어요.</td></tr>';
}

// ── CSV ──
function downloadCsv() {
  if (!statRows.length) return;
  const cols = ['날짜', '프로그램', '장소', '학번', '이름', '원래시각', '퇴실시각', '퇴실방식', '상태', '교사', '사후여부'];
  const cell = (v) => {
    let s = v == null ? '' : String(v);
    // Excel 수식 인젝션 방어 — 교사/이름 등 자유 입력 값이 =HYPERLINK(...) 등으로 실행되는 것 차단
    if (/^[=+\-@\t\r]/.test(s)) s = "'" + s;
    return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  };
  // 퇴실시각(timestamptz, UTC 직렬화)은 원래시각(KST 벽시각)과 같은 기준으로 맞춰 내보낸다
  const lines = [cols.join(',')].concat(statRows.map((r) => {
    const out = { ...r, 퇴실시각: r.퇴실시각 ? kstTime(r.퇴실시각, true) : '' };
    return cols.map((c) => cell(out[c])).join(',');
  }));
  // ﻿ = BOM — Excel이 UTF-8 한글을 제대로 열게 함
  const blob = new Blob(['﻿' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = `cosmos_출석_${(statRange && statRange.from) || '처음'}_${(statRange && statRange.to) || localDate()}.csv`;
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 4000);
}

// ══════════════ 명단 ══════════════
let rosterStudents = [];   // [{ hakbun, name, grade, rows:[…], activeN }]

async function loadRoster() {
  const btn = $('ro-reload'); btn.disabled = true;
  try {
    const rows = await allStudents();
    const map = new Map();
    for (const r of rows) {
      const k = String(r.학번);
      if (!map.has(k)) map.set(k, { hakbun: k, name: r.이름 || '', grade: /^[123]/.test(k) ? k[0] : 'etc', rows: [], activeN: 0 });
      const s = map.get(k); s.rows.push(r); if (r.활성) s.activeN++; if (!s.name && r.이름) s.name = r.이름;
    }
    rosterStudents = [...map.values()].sort((a, b) => a.hakbun.localeCompare(b.hakbun));
    paintRoster();
  } catch (e) {
    toast('명단을 불러오지 못했어요: ' + (e.message || '오류'), 'err');
  } finally { btn.disabled = false; }
}

function paintRoster() {
  const q = ($('ro-search').value || '').trim().toLowerCase();
  const grade = $('ro-grade').value;
  const act = $('ro-active').value;
  const prog = $('ro-program').value;
  const list = rosterStudents.filter((s) => {
    if (q && !(s.hakbun.includes(q) || s.name.toLowerCase().includes(q))) return false;
    if (grade && s.grade !== grade) return false;
    if (act === 'on' && s.activeN === 0) return false;
    if (act === 'off' && s.activeN > 0) return false;
    if (prog && !s.rows.some((r) => r.프로그램 === prog)) return false;
    return true;
  });
  const activeTotal = rosterStudents.filter((s) => s.activeN > 0).length;
  $('ro-count').textContent = `${list.length}명 표시 · 전체 ${rosterStudents.length}명 (활성 ${activeTotal}명)`;
  $('ro-rows').innerHTML = list.length ? list.map((s) => {
    const anyActive = s.activeN > 0;
    const partial = anyActive && s.activeN < s.rows.length;
    const progs = s.rows.map((r) => `<span class="bdg${r.활성 ? '' : ' off'}" title="${esc(r.장소)} · ${esc((r.출석요일 || []).join(''))}">${esc(shortProg(r.프로그램))}</span>`).join('');
    const state = anyActive
      ? (partial ? '<span class="bdg warn">부분 활성</span>' : '<span class="bdg ok">활성</span>')
      : '<span class="bdg off">비활성</span>';
    const anomaly = s.grade === 'etc' ? ' <span class="bdg err" title="학년을 알 수 없는 학번이에요">학번 확인</span>' : '';
    return `<tr${anyActive ? '' : ' class="off"'}>
      <td class="num">${esc(s.hakbun)}${anomaly}</td>
      <td>${esc(s.name)}</td>
      <td class="num dim">${s.grade === 'etc' ? '?' : s.grade}</td>
      <td>${progs}</td>
      <td>${state}</td>
      <td style="text-align:right;white-space:nowrap">
        <button class="btn sm ${anyActive ? 'danger' : 'line'}" data-act="toggle" data-hakbun="${esc(s.hakbun)}" data-to="${anyActive ? '0' : '1'}">${anyActive ? '비활성화' : '활성화'}</button>
        <button class="btn sm line" data-act="pin" data-hakbun="${esc(s.hakbun)}" data-name="${esc(s.name)}">PIN 초기화</button>
      </td>
    </tr>`;
  }).join('') : '<tr class="empty"><td colspan="6">해당하는 학생이 없어요.</td></tr>';
}

const shortProg = (p) => String(p || '').replace(' 독서시간', '');

async function onRosterAction(e) {
  const btn = e.target.closest('button[data-act]');
  if (!btn) return;
  const hakbun = btn.dataset.hakbun;
  if (btn.dataset.act === 'pin') { openPinModal(hakbun, btn.dataset.name); return; }
  // 활성/비활성 토글 (학생 단위 — 전 프로그램 행 일괄)
  const toActive = btn.dataset.to === '1';
  const s = rosterStudents.find((x) => x.hakbun === hakbun);
  const label = `${hakbun} ${s ? s.name : ''}`.trim();
  if (!confirm(toActive
    ? `${label} 학생을 다시 활성화할까요?\n등록된 모든 프로그램이 활성으로 바뀌어요.`
    : `${label} 학생을 비활성화할까요?\n등록된 모든 프로그램이 비활성으로 바뀌어요. (전출 등)\n출석 기록은 지워지지 않아요.`)) return;
  btn.disabled = true;
  try {
    const res = await setStudentActive(hakbun, toActive);
    toast(`${label} — ${toActive ? '활성화' : '비활성화'} 완료 (${(res && res.updated) || 0}개 프로그램)`, 'ok');
    if (s) s.rows.forEach((r) => { r.활성 = toActive; });
    if (s) s.activeN = toActive ? s.rows.length : 0;
    paintRoster();
  } catch (err) {
    if (isRpcMissing(err)) toast('서버 함수가 아직 없어요 — docs/w3_migration.sql을 먼저 적용해주세요', 'err');
    else toast('변경 실패: ' + (err.message || '오류'), 'err');
  } finally { btn.disabled = false; }
}

// ── PIN 초기화 모달 ──
function openPinModal(hakbun, name) {
  $('md-name').textContent = `${hakbun} ${name || ''}`.trim();
  $('md-cmd').textContent = `node reset-pin.mjs ${hakbun}`;
  $('modal-bg').classList.add('on');
}
function closeModal() { $('modal-bg').classList.remove('on'); }

async function copyText(text) {
  try { await navigator.clipboard.writeText(text); toast('복사됐어요', 'ok'); }
  catch (_) {
    const ta = document.createElement('textarea'); ta.value = text; document.body.appendChild(ta);
    ta.select(); document.execCommand('copy'); ta.remove(); toast('복사됐어요', 'ok');
  }
}

// ══════════════ 설정 / 진단 ══════════════
async function runDiag() {
  const ul = $('dg-list');
  ul.innerHTML = '<li><span class="st na">·</span>확인 중…</li>';
  const items = [];
  const add = (ok, label, detail) => items.push({ ok, label, detail: detail || '' });

  const user = await currentUser().catch(() => null);
  add(!!user, '로그인', user ? (user.email || '') : '세션 없음');
  add(await isStaff(), 'is_staff() — 교직원 인증', '');

  const adm = await isAdmin();
  if (adm === null) add('na', 'is_admin() — 관리자 판별 함수', '미배포 · 이메일 확인으로 동작 중 (w3_migration.sql)');
  else add(adm, 'is_admin() — 관리자 판별 함수', adm ? 'role=admin 확인' : 'role이 admin이 아니에요');

  // ⚠️ RLS 정책 부재 = 에러가 아니라 0행 — 0행이면 '정책 미적용 가능성'으로 표기
  for (const [table, label] of [['students', '명단 읽기'], ['attendance', '출석 읽기'], ['sessions', '세션 읽기']]) {
    try {
      const { count, error } = await sb().from(table).select('*', { count: 'exact', head: true });
      if (error) throw error;
      if (count) add(true, label, `${count.toLocaleString()}행`);
      else add('na', label, '0행 — 읽기 정책 미적용이거나 데이터 없음 (w3_migration.sql 확인)');
    } catch (e) {
      add(false, label, e.message || '오류');
    }
  }
  try {
    const { data, error } = await sb().from('staff').select('role').limit(1);
    if (error) throw error;
    if (data && data.length) add(true, 'staff 본인 행 읽기', `role=${data[0].role}`);
    else add('na', 'staff 본인 행 읽기', '0행 — 본인 행 읽기 정책 미적용 (w3_migration.sql)');
  } catch (e) {
    // v2 하드닝의 GRANT 회수 상태(permission denied) = 마이그레이션 전 정상
    if (/permission denied/i.test(e.message || '')) add('na', 'staff 본인 행 읽기', '미적용 — w3_migration.sql 적용 후 role 표시');
    else add(false, 'staff 본인 행 읽기', e.message || '오류');
  }
  try {
    // 존재하지 않는 학번으로 무해 프로브 (0행 갱신)
    await setStudentActive('__probe__', true);
    add(true, 'admin_set_student_active_v3 — 활성 토글 함수', '배포됨');
  } catch (e) {
    if (isRpcMissing(e)) add('na', 'admin_set_student_active_v3 — 활성 토글 함수', '미배포 (w3_migration.sql)');
    else if (/관리자 권한/.test(e.message || '')) add(false, 'admin_set_student_active_v3 — 활성 토글 함수', '배포됨 · 권한 거부(role 확인 필요)');
    else add(false, 'admin_set_student_active_v3 — 활성 토글 함수', e.message || '오류');
  }

  ul.innerHTML = items.map((it) => {
    const cls = it.ok === 'na' ? 'na' : (it.ok ? 'ok' : 'bad');
    const mark = it.ok === 'na' ? '—' : (it.ok ? '✓' : '✗');
    return `<li><span class="st ${cls}">${mark}</span>${esc(it.label)}<span class="d">${esc(it.detail)}</span></li>`;
  }).join('');
}

async function doSettingsPinChange() {
  const p1 = $('set-pin1').value.trim(), p2 = $('set-pin2').value.trim();
  const btn = $('set-pin-btn');
  if (!/^\d{6,12}$/.test(p1)) { toast('관리자 PIN은 숫자 6~12자리로 해주세요'); return; }
  if (p1 !== p2) { toast('두 PIN이 일치하지 않아요'); return; }
  btn.disabled = true; btn.textContent = '저장 중…';
  try { await changePin(p1); $('set-pin1').value = ''; $('set-pin2').value = ''; toast('PIN이 변경됐어요', 'ok'); }
  catch (e) { toast('변경 실패: ' + (e.message || '오류'), 'err'); }
  finally { btn.disabled = false; btn.textContent = 'PIN 변경'; }
}

async function doLogout() {
  stopTodayPolling();
  await logout();
  loadedOnce.clear();
  show('view-login');
}

// ── 차트 툴팁 ──
function bindChartTooltip() {
  const tip = $('ctip');
  const chart = $('st-chart');
  chart.addEventListener('mousemove', (e) => {
    const col = e.target.closest('.col');
    if (!col) { tip.classList.remove('on'); return; }
    tip.textContent = '';
    const parts = (col.dataset.tip || '').split(' · ');
    tip.innerHTML = parts.map((p, i) => (i === 0 ? esc(p) : `<b>${esc(p)}</b>`)).join(' · ');
    tip.classList.add('on');
    const pad = 14;
    let x = e.clientX + pad, y = e.clientY - 34;
    const w = tip.offsetWidth || 120;
    if (x + w + 8 > innerWidth) x = e.clientX - w - pad;
    tip.style.left = x + 'px'; tip.style.top = Math.max(8, y) + 'px';
  });
  chart.addEventListener('mouseleave', () => tip.classList.remove('on'));
}

// ── 바인딩 ──
window.addEventListener('DOMContentLoaded', () => {
  $('a-login-btn').addEventListener('click', doLogin);
  $('a-pin').addEventListener('keydown', (e) => { if (e.key === 'Enter') doLogin(); });
  $('a-pin-btn').addEventListener('click', doFirstPinChange);
  $('a-pin-new2').addEventListener('keydown', (e) => { if (e.key === 'Enter') doFirstPinChange(); });

  document.querySelectorAll('.tab').forEach((b) => b.addEventListener('click', () => switchTab(b.dataset.tab)));

  $('st-range').addEventListener('change', () => {
    const custom = $('st-range').value === 'custom';
    $('st-custom-from-wrap').classList.toggle('hidden', !custom);
    $('st-custom-to-wrap').classList.toggle('hidden', !custom);
  });
  $('st-load').addEventListener('click', loadStats);
  $('st-csv').addEventListener('click', downloadCsv);
  $('st-search').addEventListener('input', paintStudentTable);
  bindChartTooltip();

  $('ro-reload').addEventListener('click', loadRoster);
  for (const id of ['ro-search', 'ro-grade', 'ro-active', 'ro-program']) {
    $(id).addEventListener(id === 'ro-search' ? 'input' : 'change', paintRoster);
  }
  $('ro-rows').addEventListener('click', onRosterAction);

  $('md-close').addEventListener('click', closeModal);
  $('md-copy').addEventListener('click', () => copyText($('md-cmd').textContent));
  $('modal-bg').addEventListener('click', (e) => { if (e.target === $('modal-bg')) closeModal(); });
  document.querySelectorAll('button[data-copy]').forEach((b) => b.addEventListener('click', () => copyText(b.dataset.copy)));

  $('dg-run').addEventListener('click', runDiag);
  $('set-pin-btn').addEventListener('click', doSettingsPinChange);
  $('a-logout').addEventListener('click', doLogout);

  document.addEventListener('visibilitychange', () => {
    if (!document.hidden && currentTab === 'today' && $('view-main').classList.contains('on')) loadToday();
  });

  boot();
});
