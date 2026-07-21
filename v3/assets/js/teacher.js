// 코스모스 출석 v3 — 교사 페이지 (로그인 · 세션 시작 · 명단 · 퇴실코드 · 마감)
import { sb, setAuthStorageKey, logout, currentUser, isStaff, createSession, issueExitCode, finalizeSession, sessionRoster } from './sb.js';
import { STAFF_EMAIL, PROGRAMS, ROOMS } from './config.js';

// 교사 세션은 학생과 별도 저장키 — 같은 브라우저에서 교사·학생 동시 로그인 가능
setAuthStorageKey('cosmos_v3_staff');

const $ = (id) => document.getElementById(id);
const REDUCE = matchMedia('(prefers-reduced-motion: reduce)').matches;
const VIEWS = ['view-loading', 'view-login', 'view-setup', 'view-session'];
function show(id) {
  for (const v of VIEWS) { const el = $(v); if (!el) continue; el.classList.toggle('on', v === id); if (v !== id) el.classList.remove('enter'); }
  const t = $(id); if (t && id !== 'view-loading' && !REDUCE) { void t.offsetWidth; t.classList.add('enter'); }
}
let toastTimer;
function toast(msg, kind) {
  const t = $('toast'); t.textContent = msg; t.className = 'toast on' + (kind ? ' ' + kind : '');
  clearTimeout(toastTimer); toastTimer = setTimeout(() => { t.className = 'toast'; }, 2800);
}
const fmtTime = (v) => { if (!v) return ''; const s = String(v); const m = s.match(/(\d{2}):(\d{2})/); return m ? `${m[1]}:${m[2]}` : s; };

// 세션 상태
let SESSION = null;       // { session_id, program, room }
let rosterTimer = null, exitTimer = null, exitExpiry = null;

// ── 부팅 ──
async function boot() {
  show('view-loading');
  let user;
  try { user = await currentUser(); } catch (e) { show('view-login'); return; }
  if (user && (await isStaff())) enterSetup();
  else show('view-login');
}

// ── 로그인 ──
async function doLogin() {
  const pin = $('t-pin').value.trim();
  const btn = $('t-login-btn');
  if (pin.length < 4) { toast('PIN을 입력해주세요'); return; }
  btn.disabled = true; btn.textContent = '확인 중…';
  try {
    const { error } = await sb().auth.signInWithPassword({ email: STAFF_EMAIL, password: pin });
    if (error) throw error;
    if (!(await isStaff())) { toast('교사 계정이 아니에요. 관리자에게 문의해주세요', 'err'); await logout(); return; }
    enterSetup();
  } catch (e) {
    toast(/Invalid login/i.test(e.message || '') ? 'PIN이 올바르지 않아요' : ('로그인 실패: ' + (e.message || '오류')), 'err');
  } finally {
    btn.disabled = false; btn.textContent = '로그인';
  }
}

// ── 세션 시작 화면 ──
function enterSetup() {
  stopPolling();
  const prog = $('t-program'), room = $('t-room');
  if (!prog.options.length) { prog.innerHTML = PROGRAMS.map((p) => `<option>${p}</option>`).join(''); }
  if (!room.options.length) { room.innerHTML = ROOMS.map((r) => `<option>${r}</option>`).join(''); }
  show('view-setup');
}

async function startSession() {
  const program = $('t-program').value, room = $('t-room').value, teacher = $('t-teacher').value.trim();
  const btn = $('t-start-btn');
  if (!teacher) { toast('담당 교사 이름을 입력해주세요'); return; }
  btn.disabled = true; btn.textContent = '시작 중…';
  try {
    const res = await createSession(program, room, teacher);
    SESSION = { session_id: res.session_id, program, room };
    $('s-meta').textContent = `${program} · ${room}`;
    $('s-entry').textContent = res.entry_code;
    $('s-exitwrap').classList.add('hidden');
    clearExitCountdown();
    show('view-session');
    startPolling();
  } catch (e) {
    toast('시작 실패: ' + (e.message || '오류'), 'err');
  } finally {
    btn.disabled = false; btn.textContent = '▶ 출석 시작';
  }
}

// ── 명단 폴링 ──
function startPolling() { renderRoster(); stopPolling(); rosterTimer = setInterval(renderRoster, 5000); }
function stopPolling() { if (rosterTimer) { clearInterval(rosterTimer); rosterTimer = null; } }

async function renderRoster() {
  if (!SESSION) return;
  let rows;
  try { rows = await sessionRoster(SESSION.session_id); } catch (e) { return; }
  const inN = rows.length, outN = rows.filter((r) => r.퇴실시각).length;
  $('s-in').textContent = inN; $('s-out').textContent = outN;
  const ul = $('s-roster');
  if (!rows.length) { ul.innerHTML = '<li class="empty">아직 입실한 학생이 없어요.</li>'; return; }
  ul.innerHTML = rows.map((r) => {
    const badge = r.퇴실시각 ? '<span class="b out">퇴실</span>' : '<span class="b in">재실</span>';
    return `<li><span class="nm">${r.이름 || ''}</span><span class="no">${r.학번 || ''}</span>${badge}<span class="t">${fmtTime(r.원래시각)}</span></li>`;
  }).join('');
}

// ── 퇴실 코드 발급 ──
async function issueExit() {
  if (!SESSION) return;
  const btn = $('s-issue-btn'); btn.disabled = true;
  try {
    const res = await issueExitCode(SESSION.session_id);
    $('s-exit').textContent = res.code;
    $('s-exitwrap').classList.remove('hidden');
    exitExpiry = Date.now() + 10 * 60 * 1000;
    startExitCountdown();
    toast('퇴실 코드가 발급됐어요 (10분)', 'ok');
  } catch (e) {
    toast('발급 실패: ' + (e.message || '오류'), 'err');
  } finally { btn.disabled = false; }
}
function startExitCountdown() {
  clearExitCountdown();
  const tick = () => {
    const left = Math.max(0, Math.round((exitExpiry - Date.now()) / 1000));
    const m = Math.floor(left / 60), s = left % 60;
    $('s-exit-cd').textContent = left > 0 ? `${m}:${String(s).padStart(2, '0')} 남음` : '만료됨 — 다시 발급해주세요';
    if (left <= 0) clearExitCountdown();
  };
  tick(); exitTimer = setInterval(tick, 1000);
}
function clearExitCountdown() { if (exitTimer) { clearInterval(exitTimer); exitTimer = null; } }

// ── 마감 ──
async function finalize() {
  if (!SESSION) return;
  if (!confirm('이 세션을 마감할까요?\n아직 퇴실 안 한 학생은 "퇴실미확인"으로 기록돼요.')) return;
  const btn = $('s-finalize-btn'); btn.disabled = true; btn.textContent = '마감 중…';
  try {
    const res = await finalizeSession(SESSION.session_id);
    stopPolling(); clearExitCountdown();
    toast(res.missing > 0 ? `마감 완료 · 퇴실미확인 ${res.missing}명` : '마감 완료 · 전원 퇴실', 'ok');
    SESSION = null;
    setTimeout(enterSetup, 900);
  } catch (e) {
    toast('마감 실패: ' + (e.message || '오류'), 'err');
  } finally { btn.disabled = false; btn.textContent = '마감'; }
}

async function doLogout() { stopPolling(); clearExitCountdown(); await logout(); show('view-login'); }
function backToSetup() { if (confirm('세션은 계속 열려 있어요. 목록으로 돌아갈까요?')) { stopPolling(); clearExitCountdown(); enterSetup(); } }

window.addEventListener('DOMContentLoaded', () => {
  $('t-login-btn').addEventListener('click', doLogin);
  $('t-pin').addEventListener('keydown', (e) => { if (e.key === 'Enter') doLogin(); });
  $('t-start-btn').addEventListener('click', startSession);
  $('t-logout-btn').addEventListener('click', doLogout);
  $('s-issue-btn').addEventListener('click', issueExit);
  $('s-finalize-btn').addEventListener('click', finalize);
  $('s-back-btn').addEventListener('click', backToSetup);
  boot();
});
