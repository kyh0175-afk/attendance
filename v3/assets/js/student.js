// 코스모스 출석 v3 — 학생 페이지 컨트롤러 (로그인 · PIN변경 · 대시보드)
import {
  setAuthStorageKey, login, logout, currentUser, hakbunOf, mustChangePin, changePin,
  myProfile, myAttendance, checkIn, checkOut, esc, monthKST, isAuthError, onSignedOut,
} from './sb.js';

// ★ 학생 저장키를 명시적으로 지정 (HANDOFF §3). sb.js 기본값에 암묵 의존하면
//   기본값이 바뀌는 순간 292명 전원이 조용히 로그아웃된다.
setAuthStorageKey('cosmos_v3_auth');

const $ = (id) => document.getElementById(id);
const REDUCE = matchMedia('(prefers-reduced-motion: reduce)').matches;
const buzz = (ms = 12) => { try { navigator.vibrate && navigator.vibrate(ms); } catch (_) {} };

const VIEWS = ['view-loading', 'view-login', 'view-pin', 'view-dash'];
function show(id) {
  for (const v of VIEWS) {
    const el = $(v);
    if (!el) continue;
    if (v === id) el.classList.add('on');
    else el.classList.remove('on', 'enter');
  }
  const t = $(id);
  if (t && id !== 'view-loading') { void t.offsetWidth; t.classList.add('enter'); } // 애니메이션 리트리거
}

let toastTimer;
function toast(msg, kind) {
  const t = $('toast');
  t.textContent = msg;
  t.className = 'toast on' + (kind ? ' ' + kind : '');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.className = 'toast'; }, 2600);
}

function countUp(el, to) {
  to = +to || 0;
  if (REDUCE || to <= 0) { el.textContent = to; return; }
  const dur = 900, t0 = performance.now();
  (function tick(now) {
    const t = Math.min(1, (now - t0) / dur);
    el.textContent = Math.round(to * (1 - Math.pow(1 - t, 3)));
    if (t < 1) requestAnimationFrame(tick);
  })(performance.now());
}

function fmtDate(s) {
  if (!s) return '';
  const p = s.split('-');
  if (p.length < 3) return s;
  const d = new Date(s + 'T00:00:00');
  const wd = ['일', '월', '화', '수', '목', '금', '토'][d.getDay()];
  return wd ? `${+p[1]}.${+p[2]} ${wd}` : `${+p[1]}.${+p[2]}`;   // 비정상 날짜에 'undefined' 방지
}

// Supabase Auth의 영문 오류를 학생이 읽을 수 있는 문구로 변환
function authMsg(e) {
  const m = String((e && e.message) || '');
  if (/Invalid login/i.test(m)) return '학번 또는 PIN이 올바르지 않아요';
  if (/should be different/i.test(m)) return '지금 쓰는 PIN과 다른 PIN으로 해주세요';
  const len = m.match(/at least (\d+) characters/i);
  if (len) return `새 PIN은 최소 ${len[1]}자리여야 해요`;
  if (/rate limit|too many/i.test(m)) return '잠시 후 다시 시도해주세요';
  if (isAuthError(e)) return '로그인이 만료됐어요. 다시 로그인해주세요';
  if (/Failed to fetch|NetworkError|load 실패/i.test(m)) return '연결이 불안정해요. 잠시 후 다시 시도해주세요';
  return m || '오류';
}

// 인증 만료면 로그인 화면으로 되돌린다 (true 반환 = 처리함)
async function bounceIfExpired(e) {
  if (!isAuthError(e)) return false;
  try { await logout(); } catch (_) {}
  toast('로그인이 만료됐어요. 다시 로그인해주세요', 'err');
  show('view-login');
  return true;
}

// ── 부팅 ──
async function boot() {
  show('view-loading');
  let user;
  try { user = await currentUser(); } catch (e) { show('view-login'); return; }
  if (!user) { show('view-login'); return; }
  if (mustChangePin(user)) { show('view-pin'); return; }
  await renderDash(user);
}

// ── 로그인 ──
async function doLogin() {
  const btn = $('login-btn');
  if (btn.disabled) return;            // ★ Enter 키는 disabled를 우회한다 — 함수 진입에서 막아야 중복 제출이 안 난다
  const hakbun = $('login-hakbun').value.trim();
  const pin = $('login-pin').value.trim();
  if (!/^\d{4,6}$/.test(hakbun)) { toast('학번을 정확히 입력해주세요'); return; }
  if (pin.length < 4) { toast('PIN을 입력해주세요'); return; }
  btn.disabled = true; btn.textContent = '확인 중…';
  let user = null;
  try {
    await login(hakbun, pin);
    buzz();
    user = await currentUser();
  } catch (e) {
    toast(authMsg(e), 'err');
    return;
  } finally {
    btn.disabled = false; btn.textContent = '로그인';
  }
  if (mustChangePin(user)) show('view-pin');
  else await renderDash(user);
}

// ── PIN 변경 (최초) ──
async function doChangePin() {
  const btn = $('pin-btn');
  if (btn.disabled) return;            // ★ Enter 키 중복 제출 방지 (changePin 2회 발사 → 두 번째가 영문 에러)
  const p1 = $('pin-new').value.trim();
  const p2 = $('pin-new2').value.trim();
  if (!/^\d{4,6}$/.test(p1)) { toast('새 PIN은 숫자 4~6자리로 해주세요'); return; }
  if (p1 !== p2) { toast('두 PIN이 일치하지 않아요'); return; }
  btn.disabled = true; btn.textContent = '저장 중…';
  try {
    await changePin(p1);
  } catch (e) {
    toast(authMsg(e), 'err');
    return;
  } finally {
    btn.disabled = false; btn.textContent = 'PIN 설정하기';
  }
  // ★ 여기서부터는 PIN이 이미 바뀐 상태다. 이후 실패를 '변경 실패'로 표시하면
  //   학생이 옛 PIN으로 재로그인을 시도해 계정이 고장난 것으로 오해한다.
  buzz(18);
  toast('PIN이 설정됐어요', 'ok');
  let user = null;
  try { user = await currentUser(); } catch (_) {}
  if (user) await renderDash(user);
  else { toast('새 PIN으로 다시 로그인해주세요', 'ok'); show('view-login'); }
}

// ── 대시보드 ──
async function renderDash(user) {
  show('view-dash');
  const hakbun = hakbunOf(user);
  $('dash-hakbun').textContent = hakbun || '';
  try {
    const [profile, att] = await Promise.all([myProfile(), myAttendance()]);
    const name = (profile[0] && profile[0].이름) || '';
    $('dash-name').innerHTML = name ? `<b>${esc(name)}</b> 님` : `<b>${esc(hakbun)}</b> 님`;

    const ym = monthKST();   // ★ UTC 기준이면 매월 1일 오전 9시 전까지 전월로 집계된다
    const month = att.filter((a) => (a.날짜 || '').slice(0, 7) === ym).length;
    countUp($('stat-month'), month);
    countUp($('stat-total'), att.length);
    $('hero-sub').innerHTML = att.length ? `지금까지 전체 <b>${att.length}</b>번 나왔어요` : '첫 출석을 기다리고 있어요';
    $('log-cnt').textContent = att.length ? `${att.length}건` : '';

    const list = $('dash-list');
    if (!att.length) { list.innerHTML = '<li class="empty">아직 출석 기록이 없어요.</li>'; return; }
    list.innerHTML = att.slice(0, 30).map((a) => {
      const miss = a.상태 === '퇴실미확인';
      const badge = a.퇴실시각 ? '<span class="badge ok">퇴실</span>'
        : (miss ? '<span class="badge warn">퇴실미확인</span>' : '');
      return `<li>
        <span class="dot ${miss ? 'miss' : ''}"></span>
        <span class="meta"><span class="d">${fmtDate(a.날짜)}</span><span class="p">${esc(a.프로그램 || '')} · ${esc(a.장소 || '')}</span></span>
        ${badge}
      </li>`;
    }).join('');
  } catch (e) {
    if (await bounceIfExpired(e)) return;
    $('dash-name').innerHTML = `<b>${esc(hakbun)}</b> 님`;
    // ★ 실패했는데 하드코딩 0을 그대로 두면 "이번 달 출석 0번"으로 읽혀 재입실을 시도한다.
    $('stat-month').textContent = '—';
    $('stat-total').textContent = '—';
    $('hero-sub').textContent = '기록을 불러오지 못했어요';
    $('log-cnt').textContent = '';
    $('dash-list').innerHTML = '<li class="empty">기록을 불러오지 못했어요. 당겨서 새로고침 해주세요.</li>';
    toast('기록을 불러오지 못했어요. 잠시 후 다시 시도해주세요', 'err');
  }
}

// ── 입실 / 퇴실 시트 ──
let sheetMode = 'in';
let sheetBusy = false;
function openSheet(mode) {
  sheetMode = mode;
  $('sheet-title').textContent = mode === 'in' ? '입실 코드' : '퇴실 코드';
  $('sheet-sub').textContent = mode === 'in'
    ? '칠판에 적힌 입실 코드 4자리를 입력해요'
    : '선생님이 안내한 퇴실 코드 4자리를 입력해요';
  $('code-input').value = '';
  $('sheet-bg').classList.add('on');
  setTimeout(() => $('code-input').focus(), 260);
}
function closeSheet() { $('sheet-bg').classList.remove('on'); $('code-input').blur(); }

async function submitCode() {
  if (sheetBusy) return;
  const code = $('code-input').value.trim();
  if (!/^\d{4}$/.test(code)) { toast('코드 4자리를 입력해주세요'); return; }
  sheetBusy = true;
  const btn = $('code-submit'); btn.disabled = true; btn.textContent = '확인 중…';
  let res;
  try {
    res = sheetMode === 'in' ? await checkIn(code) : await checkOut(code);
  } catch (e) {
    if (!(await bounceIfExpired(e))) toast('처리 실패: ' + authMsg(e), 'err');
    return;
  } finally {
    sheetBusy = false; btn.disabled = false; btn.textContent = '확인';
  }
  if (!res || res.ok === false) { toast((res && res.msg) || '코드를 다시 확인해주세요', 'err'); return; }
  // ★ 여기서부터는 출석이 이미 기록된 상태 — 이후 실패를 '처리 실패'로 표시하면 안 된다.
  buzz(18);
  if (sheetMode === 'in') {
    toast(res.already ? '이미 입실했어요' : `입실 완료 · ${res.장소 || ''}`.trim(), 'ok');
  } else {
    toast(res.already ? '이미 퇴실했어요' : '퇴실 완료! 오늘도 수고했어요', 'ok');
  }
  closeSheet();
  try {
    const user = await currentUser();
    if (user) await renderDash(user);
  } catch (_) { /* 대시보드 갱신 실패는 출석 결과와 무관 — 조용히 넘어간다 */ }
}

let loggingOut = false;
async function doLogout() {
  loggingOut = true;
  try { await logout(); } catch (_) {}
  $('login-pin').value = '';
  $('login-hakbun').value = '';
  show('view-login');
  loggingOut = false;
}

// ── 바인딩 ──
window.addEventListener('DOMContentLoaded', () => {
  $('login-btn').addEventListener('click', doLogin);
  $('login-pin').addEventListener('keydown', (e) => { if (e.key === 'Enter') doLogin(); });
  $('login-hakbun').addEventListener('keydown', (e) => { if (e.key === 'Enter') $('login-pin').focus(); });
  $('pin-btn').addEventListener('click', doChangePin);
  $('pin-new2').addEventListener('keydown', (e) => { if (e.key === 'Enter') doChangePin(); });
  $('dash-logout').addEventListener('click', doLogout);
  // 친구 학번으로 잘못 로그인했을 때 PIN 변경 화면에서 빠져나올 수 있게 (탈출구)
  const pinBack = $('pin-logout');
  if (pinBack) pinBack.addEventListener('click', doLogout);
  $('btn-checkin').addEventListener('click', () => openSheet('in'));
  $('btn-checkout').addEventListener('click', () => openSheet('out'));
  $('code-submit').addEventListener('click', submitCode);
  $('code-cancel').addEventListener('click', closeSheet);
  $('code-input').addEventListener('keydown', (e) => { if (e.key === 'Enter') submitCode(); });
  $('sheet-bg').addEventListener('click', (e) => { if (e.target === $('sheet-bg')) closeSheet(); });
  // 리프레시 토큰이 무효화되면 supabase-js가 SIGNED_OUT을 발생시킨다 → 로그인 화면으로 복귀
  onSignedOut(() => {
    if (loggingOut) return;                     // 사용자가 직접 로그아웃한 경우는 제외
    toast('로그인이 만료됐어요. 다시 로그인해주세요', 'err');
    show('view-login');
  });
  boot();
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
});
