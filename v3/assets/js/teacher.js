// 코스모스 출석 v3 — 교사 페이지 (로그인 · 세션 시작 · 명단 · 퇴실코드 · 마감)
import { sb, setAuthStorageKey, logout, currentUser, isStaff, createSession, issueExitCode, finalizeSession, sessionRoster, manualAttendance, activeSessions, esc, isAuthError, onSignedOut } from './sb.js';
import { STAFF_EMAIL, PROGRAMS, ROOMS, guessEndTime, AUTO_EXIT_LEAD_MIN } from './config.js';

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
const pad2 = (n) => String(n).padStart(2, '0');
const hhmm = (ms) => { const d = new Date(ms); return `${pad2(d.getHours())}:${pad2(d.getMinutes())}`; };

// 'HH:MM'(교사가 화면에서 보는 벽시계 시각) → 오늘 날짜의 타임스탬프.
// ★ 기기 시계를 그대로 쓴다. 전자칠판·교사 노트북은 KST이므로 변환이 필요 없고,
//   변환을 넣으면 오히려 교사가 입력한 값과 화면 표시가 어긋난다.
function endAtFromTime(v) {
  if (!v) return 0;
  const m = String(v).match(/^(\d{1,2}):(\d{2})$/);
  if (!m) return 0;
  const d = new Date();
  d.setHours(Number(m[1]), Number(m[2]), 0, 0);
  return d.getTime();
}

// 세션 상태
let SESSION = null;       // { session_id, program, room, teacher, entry_code }
let rosterTimer = null, exitTimer = null, exitExpiry = null;
let rosterRows = [];      // 최근 명단 (학년 필터·재렌더용)
let gradeFilter = '';     // '' | '1' | '2' | '3'
let exitIssued = false;   // 퇴실 코드 발급 여부 (마감 버튼 게이트)
let rosterInFlight = false;   // 폴링 중복 실행 방지 (느린 회선에서 응답 역전 차단)
let rosterFailStreak = 0;     // 연속 실패 횟수 (교사에게 표시)
let loggingOut = false;       // 사용자가 직접 로그아웃한 경우 SIGNED_OUT 알림 억제
let autoTimer = null;         // 퇴실 코드 자동 발급 감시 틱

// ── 세션 영속 ──
// ★ 세션이 메모리에만 있으면 전자칠판 탭이 한 번만 리로드돼도 진행 중 세션으로 돌아갈 길이 없다.
//   새 세션을 시작하면 기존 출석 행이 옛 세션id에 묶여 퇴실·마감이 모두 막힌다.
const SKEY = 'cosmos_v3_teacher_session';
function saveSession() {
  try { localStorage.setItem(SKEY, JSON.stringify(SESSION)); } catch (_) {}
}
function clearSavedSession() {
  SESSION = null;
  try { localStorage.removeItem(SKEY); } catch (_) {}
}
function loadSavedSession() {
  try {
    const raw = localStorage.getItem(SKEY);
    if (!raw) return null;
    const o = JSON.parse(raw);
    return (o && o.session_id) ? o : null;
  } catch (_) { return null; }
}

// ── 부팅 ──
async function boot() {
  show('view-loading');
  let user;
  try { user = await currentUser(); } catch (e) { show('view-login'); return; }
  if (!user) { show('view-login'); return; }
  let staff = false;
  try {
    staff = await isStaff();
  } catch (e) {
    // ★ 네트워크 오류를 '권한 없음'으로 처리하면 안 된다 (로그아웃 금지 — 세션은 유효하다)
    show('view-login');
    toast(isAuthError(e) ? '로그인이 만료됐어요. 다시 로그인해주세요' : '연결이 불안정해요. 잠시 후 새로고침 해주세요', 'err');
    return;
  }
  if (!staff) { show('view-login'); return; }
  if (await tryRestoreSession()) return;   // 진행 중 세션이 있으면 복귀
  enterSetup();
}

// 새로고침·탭 리로드 후 진행 중 세션으로 복귀
async function tryRestoreSession() {
  const saved = loadSavedSession();
  if (!saved) return false;
  let rows;
  try { rows = await activeSessions(); } catch (e) { return false; }
  // ★ 쌍둥이 장소(아우름/교과1실)는 같은 세션id로 두 행이 존재할 수 있다 — filter 후 첫 행 사용
  const match = rows.filter((r) => String(r.세션id) === String(saved.session_id));
  if (!match.length) {
    // 활성 세션이 여럿 있는데 그중 없다 = 확실히 마감됨 → 저장본 폐기.
    // 목록이 비어 있으면 RLS 정책 미적용으로 0행일 수도 있으므로 저장본을 남긴다.
    if (rows.length) clearSavedSession();
    return false;
  }
  const row = match[0];

  SESSION = saved;
  $('top-sess').innerHTML = `${esc(saved.program)} · <span class="rm">${esc(saved.room)}</span> · ${esc(saved.teacher || '')}`;
  $('s-entry').textContent = row.입실코드 || saved.entry_code || '----';
  resetRosterView();
  gradeFilter = ''; updateGradeSeg();

  // 퇴실 코드는 DB 값이 권위 — 클라 추정치보다 정확하다
  const exp = row.퇴실코드만료 ? new Date(row.퇴실코드만료).getTime() : 0;
  if (row.퇴실코드 && exp) {
    $('s-exit').textContent = row.퇴실코드;
    $('s-exitwrap').classList.remove('hidden');
    exitExpiry = exp;
    exitIssued = true;
    $('s-issue-btn').textContent = '퇴실 코드 재발급';
    $('s-finalize-btn').style.display = '';
    startExitCountdown();
  } else {
    $('s-exitwrap').classList.add('hidden');
    exitIssued = false;
    $('s-issue-btn').textContent = '퇴실 코드 발급';
    $('s-finalize-btn').style.display = 'none';
  }
  show('view-session');
  startPolling();
  armAutoExit();              // 저장해둔 종료 시각으로 자동 발급 감시 재개
  toast('진행 중이던 출석으로 돌아왔어요', 'ok');
  return true;
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
    let staff;
    try {
      staff = await isStaff();
    } catch (e2) {
      // ★ 판정 실패는 권한 문제가 아니다 — 성공한 로그인을 날리지 않는다
      toast('연결이 불안정해요. 잠시 후 다시 시도해주세요', 'err');
      return;
    }
    if (!staff) { toast('교사 계정이 아니에요. 관리자에게 문의해주세요', 'err'); await logout(); return; }
    if (await tryRestoreSession()) return;
    enterSetup();
  } catch (e) {
    toast(/Invalid login/i.test(e.message || '') ? 'PIN이 올바르지 않아요' : ('로그인 실패: ' + (e.message || '오류')), 'err');
  } finally {
    btn.disabled = false; btn.textContent = '로그인';
  }
}

// 명단 표시 초기화 — ★ 이걸 안 하면 새 세션 화면에 이전 세션 명단·인원이 그대로 남는다
function resetRosterView() {
  rosterRows = [];
  rosterFailStreak = 0;
  $('s-in').textContent = '0';
  $('s-out').textContent = '0';
  $('s-roster').innerHTML = '<li class="empty">명단을 불러오는 중…</li>';
}

// ── 세션 시작 화면 ──
function enterSetup() {
  stopPolling();
  clearExitCountdown();
  clearAutoExit();
  resetRosterView();
  $('top-sess').innerHTML = '';   // 상단 세션 표시 비움
  const prog = $('t-program'), room = $('t-room');
  if (!prog.options.length) { prog.innerHTML = PROGRAMS.map((p) => `<option>${p}</option>`).join(''); }
  if (!room.options.length) { room.innerHTML = ROOMS.map((r) => `<option>${r}</option>`).join(''); }
  syncEndInput();
  show('view-setup');
}

// 프로그램에 맞는 종료 시각을 입력칸에 채운다.
// 토요일은 지금 시각으로 오전·오후를 추정하므로, 어긋나면 교사가 그 자리에서 고치면 된다.
function syncEndInput() {
  const el = $('t-end');
  if (!el) return;
  el.value = guessEndTime($('t-program').value, new Date());
}

async function startSession() {
  const program = $('t-program').value, room = $('t-room').value, teacher = $('t-teacher').value.trim();
  const btn = $('t-start-btn');
  if (!teacher) { toast('담당 교사 이름을 입력해주세요'); return; }
  btn.disabled = true; btn.textContent = '시작 중…';
  try {
    const res = await createSession(program, room, teacher);
    SESSION = {
      session_id: res.session_id, program, room, teacher, entry_code: res.entry_code,
      endAt: endAtFromTime($('t-end').value),   // 퇴실 코드 자동 발급 기준
    };
    saveSession();
    // 세션 정보는 상단 바에 (프로그램 · 장소 · 교사) — 코드 카드는 코드만 크게
    $('top-sess').innerHTML = `${esc(program)} · <span class="rm">${esc(room)}</span> · ${esc(teacher)}`;
    $('s-entry').textContent = res.entry_code;
    $('s-exitwrap').classList.add('hidden');
    exitIssued = false;
    exitExpiry = null;
    $('s-issue-btn').style.display = ''; $('s-issue-btn').textContent = '퇴실 코드 발급';
    $('s-finalize-btn').style.display = 'none';
    gradeFilter = '';
    updateGradeSeg();
    clearExitCountdown();
    resetRosterView();          // ★ 이전 세션 명단·인원 초기화
    show('view-session');
    startPolling();
    armAutoExit();
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
  if (rosterInFlight) return;        // ★ 응답 역전 방지 — 느린 회선에서 옛 응답이 새 응답을 덮어쓰는 걸 막는다
  rosterInFlight = true;
  try {
    rosterRows = await sessionRoster(SESSION.session_id);
    rosterFailStreak = 0;
  } catch (e) {
    // ★ 조용히 실패하면 교사는 "아무도 안 들어온다"고 믿는다 — 화면에 표시한다
    rosterFailStreak++;
    if (rosterFailStreak === 2) toast('명단을 갱신하지 못하고 있어요. 인터넷 연결을 확인해주세요', 'err');
    if (rosterFailStreak >= 2) {
      const ul = $('s-roster');
      if (ul && !ul.querySelector('.stale-note')) {
        ul.insertAdjacentHTML('afterbegin', '<li class="empty stale-note">⚠ 연결이 끊겨 아래 명단이 최신이 아닐 수 있어요</li>');
      }
    }
    return;
  } finally {
    rosterInFlight = false;
  }
  paintRoster();
}

// 학년 필터 세그먼트 + 명단 그리기 (폴링·필터 변경 공용)
function paintRoster() {
  const rows = gradeFilter ? rosterRows.filter((r) => String(r.학번 || '')[0] === gradeFilter) : rosterRows;
  const inN = rows.length, outN = rows.filter((r) => r.퇴실시각).length;
  $('s-in').textContent = inN; $('s-out').textContent = outN;
  const ul = $('s-roster');
  if (!rosterRows.length) { ul.innerHTML = '<li class="empty">아직 입실한 학생이 없어요.</li>'; return; }
  if (!rows.length) { ul.innerHTML = '<li class="empty">이 학년은 아직 입실한 학생이 없어요.</li>'; return; }
  ul.innerHTML = rows.map((r) => {
    const badge = r.퇴실시각 ? '<span class="b out">퇴실</span>' : '<span class="b in">재실</span>';
    const man = r.메모 === '수동입실' ? '<span class="b man">수동</span>' : '';
    return `<li><span class="nm">${esc(r.이름 || '')}</span><span class="no">${esc(r.학번 || '')}</span>${badge}${man}<span class="t">${fmtTime(r.원래시각)}</span></li>`;
  }).join('');
}

function updateGradeSeg() {
  document.querySelectorAll('#s-grade button').forEach((b) => b.classList.toggle('on', b.dataset.g === gradeFilter));
}
function setGrade(g) { gradeFilter = g; updateGradeSeg(); paintRoster(); }

// ── 수동 출석 (오프라인·코드 불가) ──
async function doManual() {
  if (!SESSION) return;
  const h = $('s-manual-hakbun').value.trim();
  if (!/^\d{5}$/.test(h)) { toast('학번 5자리를 입력해주세요'); return; }
  const btn = $('s-manual-btn'); btn.disabled = true;
  try {
    const res = await manualAttendance(SESSION.session_id, h);
    if (res && res.already) toast(`${res.name || h} — 이미 출석했어요`);
    else toast(`${(res && res.name) || h} — 수동 출석 완료`, 'ok');
    $('s-manual-hakbun').value = '';
    await renderRoster();
  } catch (e) {
    toast(/명단에 없는/.test(e.message || '') ? '명단에 없는 학번이에요' : ('처리 실패: ' + (e.message || '오류')), 'err');
  } finally { btn.disabled = false; }
}

// ── 퇴실 코드 발급 ──
async function issueExit(auto) {
  if (!SESSION) return;
  const btn = $('s-issue-btn'); btn.disabled = true;
  try {
    const res = await issueExitCode(SESSION.session_id);
    $('s-exit').textContent = res.code;
    $('s-exit').classList.remove('expired');
    $('s-exitwrap').classList.remove('hidden');
    // ★ 서버가 돌려준 만료 시각을 쓴다 — 클라에서 10분을 추정하면 응답 지연만큼 항상 길게 표시된다
    const exp = res.expires_at ? new Date(res.expires_at).getTime() : 0;
    exitExpiry = exp || (Date.now() + 10 * 60 * 1000);
    startExitCountdown();
    // 퇴실 코드 발급 후에만 마감 버튼 노출 (실수 마감 방지)
    exitIssued = true;
    $('s-finalize-btn').style.display = '';
    $('s-issue-btn').textContent = '퇴실 코드 재발급';
    toast(auto ? '퇴실 코드가 자동으로 발급됐어요 (10분)' : '퇴실 코드가 발급됐어요 (10분)', 'ok');
    updateAutoHint();
  } catch (e) {
    toast('발급 실패: ' + (e.message || '오류'), 'err');
    if (auto) updateAutoHint();
  } finally { btn.disabled = false; }
}
function startExitCountdown() {
  clearExitCountdown();
  const codeEl = $('s-exit');
  const savedCode = codeEl.textContent;
  const tick = () => {
    const left = Math.max(0, Math.round((exitExpiry - Date.now()) / 1000));
    if (left <= 0) {
      // ★ 만료 안내가 13px 소문자뿐이면 뒷자리에선 안 읽힌다. 칠판의 큰 숫자 자체를 바꿔야
      //   "코드 틀렸대요 / 칠판에 있는데?" 상황이 안 생긴다.
      codeEl.textContent = '만료';
      codeEl.classList.add('expired');
      $('s-exit-cd').textContent = '퇴실 코드를 다시 발급해주세요';
      clearExitCountdown();
      return;
    }
    codeEl.textContent = savedCode;
    codeEl.classList.remove('expired');
    const m = Math.floor(left / 60), s = left % 60;
    $('s-exit-cd').textContent = `${m}:${String(s).padStart(2, '0')} 남음`;
  };
  tick(); exitTimer = setInterval(tick, 1000);
}
function clearExitCountdown() { if (exitTimer) { clearInterval(exitTimer); exitTimer = null; } }

// ── 퇴실 코드 자동 발급 (종료 N분 전) ──
// ★ 긴 setTimeout 금지. 방과후는 시작~종료가 두 시간 가까이인데, 전자칠판이 절전에
//   들어가거나 탭이 백그라운드가 되면 Chrome이 타이머를 클램프·지연시켜 제 시각에
//   안 터진다. 짧은 주기로 '벽시계'를 비교하면 절전에서 깨어나도 즉시 따라잡는다.
let autoBusy = false, autoTries = 0;
function clearAutoExit() { if (autoTimer) { clearInterval(autoTimer); autoTimer = null; } }

function armAutoExit() {
  clearAutoExit();
  autoTries = 0;
  updateAutoHint();
  if (!SESSION || !SESSION.endAt) return;
  if (exitIssued) return;
  if (Date.now() >= SESSION.endAt) return;   // 종료 시각이 이미 지남 → 수동 발급만
  autoTimer = setInterval(autoExitTick, 20000);
  autoExitTick();
}

async function autoExitTick() {
  if (!SESSION || !SESSION.endAt) { clearAutoExit(); return; }
  if (exitIssued) { clearAutoExit(); updateAutoHint(); return; }   // 교사가 먼저 발급함
  if (autoBusy) return;
  if (Date.now() < SESSION.endAt - AUTO_EXIT_LEAD_MIN * 60000) return;
  if (autoTries >= 5) { clearAutoExit(); updateAutoHint(); return; }
  autoTries++;
  autoBusy = true;
  try { await issueExit(true); } finally { autoBusy = false; }
  if (exitIssued) clearAutoExit();
}

function updateAutoHint() {
  const el = $('s-auto-hint');
  if (!el) return;
  el.classList.remove('on');
  if (exitIssued) { el.textContent = '필요하면 위 버튼으로 다시 발급할 수 있어요.'; return; }
  if (autoTries >= 5) { el.textContent = '자동 발급에 실패했어요. 위 버튼으로 직접 발급해주세요.'; return; }
  if (!SESSION || !SESSION.endAt) { el.textContent = '종료 시각이 없어 자동 발급을 하지 않아요. 때가 되면 직접 발급해주세요.'; return; }
  if (Date.now() >= SESSION.endAt) { el.textContent = '종료 시각이 지나 자동 발급을 하지 않아요. 직접 발급해주세요.'; return; }
  el.textContent = `${hhmm(SESSION.endAt - AUTO_EXIT_LEAD_MIN * 60000)}에 자동으로 발급돼요 · 종료 ${hhmm(SESSION.endAt)}`;
  el.classList.add('on');
}

// ── 마감 ──
async function finalize() {
  if (!SESSION) return;
  // 표시 계층(display:none)뿐 아니라 로직 게이트도 둔다 — 노출 조건이 늘어날 때 사고 방지
  if (!exitIssued) { toast('퇴실 코드를 먼저 발급해주세요', 'err'); return; }
  if (!confirm('이 세션을 마감할까요?\n아직 퇴실 안 한 학생은 "퇴실미확인"으로 기록돼요.')) return;
  const btn = $('s-finalize-btn'); btn.disabled = true; btn.textContent = '마감 중…';
  try {
    const res = await finalizeSession(SESSION.session_id);
    stopPolling(); clearExitCountdown(); clearAutoExit();
    toast(res.missing > 0 ? `마감 완료 · 퇴실미확인 ${res.missing}명` : '마감 완료 · 전원 퇴실', 'ok');
    clearSavedSession();
    setTimeout(enterSetup, 900);
  } catch (e) {
    toast('마감 실패: ' + (e.message || '오류') + ' — 다시 눌러주세요', 'err');
  } finally { btn.disabled = false; btn.textContent = '마감'; }
}

async function doLogout() {
  loggingOut = true;
  stopPolling(); clearExitCountdown(); clearAutoExit();
  clearSavedSession();               // 다른 교사가 이어받을 때 옛 세션으로 복귀하지 않게
  try { await logout(); } catch (_) {}
  show('view-login');
  loggingOut = false;
}
// '나가기'는 세션을 닫지 않는다 → 저장본을 지우지 않아야 새로고침 후에도 돌아올 수 있다
function backToSetup() { if (confirm('세션은 계속 열려 있어요.\n나가도 학생들은 계속 입·퇴실할 수 있고, 다시 들어오려면 새로 시작하면 돼요.\n나갈까요?')) { stopPolling(); clearExitCountdown(); clearAutoExit(); enterSetup(); } }

window.addEventListener('DOMContentLoaded', () => {
  $('t-login-btn').addEventListener('click', doLogin);
  $('t-pin').addEventListener('keydown', (e) => { if (e.key === 'Enter') doLogin(); });
  $('t-start-btn').addEventListener('click', startSession);
  $('t-logout-btn').addEventListener('click', doLogout);
  // ★ 핸들러로 직접 넘기면 첫 인자에 MouseEvent가 들어와 auto=true로 오해한다
  $('s-issue-btn').addEventListener('click', () => issueExit(false));
  $('t-program').addEventListener('change', syncEndInput);
  $('s-finalize-btn').addEventListener('click', finalize);
  $('s-back-btn').addEventListener('click', backToSetup);
  $('s-grade').addEventListener('click', (e) => { const b = e.target.closest('button[data-g]'); if (b) setGrade(b.dataset.g); });
  $('s-manual-btn').addEventListener('click', doManual);
  $('s-manual-hakbun').addEventListener('keydown', (e) => { if (e.key === 'Enter') doManual(); });
  // 리프레시 토큰 무효화 → 로그인 화면으로. 폴링을 멈춰야 실패 토스트가 계속 뜨지 않는다.
  onSignedOut(() => {
    if (loggingOut) return;
    stopPolling(); clearExitCountdown(); clearAutoExit();
    toast('로그인이 만료됐어요. 다시 로그인해주세요 (세션은 그대로 열려 있어요)', 'err');
    show('view-login');
  });
  boot();
});
