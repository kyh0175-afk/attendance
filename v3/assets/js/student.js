// 코스모스 출석 v3 — 학생 페이지 컨트롤러 (로그인 · PIN변경 · 대시보드)
import { login, logout, currentUser, hakbunOf, mustChangePin, changePin, myProfile, myAttendance, checkIn, checkOut } from './sb.js';

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
  const wd = ['일', '월', '화', '수', '목', '금', '토'][new Date(s + 'T00:00:00').getDay()];
  return `${+p[1]}.${+p[2]} ${wd}`;
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
  const hakbun = $('login-hakbun').value.trim();
  const pin = $('login-pin').value.trim();
  const btn = $('login-btn');
  if (!/^\d{4,6}$/.test(hakbun)) { toast('학번을 정확히 입력해주세요'); return; }
  if (pin.length < 4) { toast('PIN을 입력해주세요'); return; }
  btn.disabled = true; btn.textContent = '확인 중…';
  try {
    await login(hakbun, pin);
    buzz();
    const user = await currentUser();
    if (mustChangePin(user)) show('view-pin');
    else await renderDash(user);
  } catch (e) {
    toast(/Invalid login/i.test(e.message || '') ? '학번 또는 PIN이 올바르지 않아요' : ('로그인 실패: ' + (e.message || '오류')), 'err');
  } finally {
    btn.disabled = false; btn.textContent = '로그인';
  }
}

// ── PIN 변경 (최초) ──
async function doChangePin() {
  const p1 = $('pin-new').value.trim();
  const p2 = $('pin-new2').value.trim();
  const btn = $('pin-btn');
  if (!/^\d{4,6}$/.test(p1)) { toast('새 PIN은 숫자 4~6자리로 해주세요'); return; }
  if (p1 !== p2) { toast('두 PIN이 일치하지 않아요'); return; }
  btn.disabled = true; btn.textContent = '저장 중…';
  try {
    await changePin(p1);
    buzz(18);
    toast('PIN이 설정됐어요', 'ok');
    await renderDash(await currentUser());
  } catch (e) {
    toast('변경 실패: ' + (e.message || '오류'), 'err');
  } finally {
    btn.disabled = false; btn.textContent = 'PIN 설정하기';
  }
}

// ── 대시보드 ──
async function renderDash(user) {
  show('view-dash');
  const hakbun = hakbunOf(user);
  $('dash-hakbun').textContent = hakbun || '';
  try {
    const [profile, att] = await Promise.all([myProfile(), myAttendance()]);
    const name = (profile[0] && profile[0].이름) || '';
    $('dash-name').innerHTML = name ? `<b>${name}</b> 님` : `<b>${hakbun}</b> 님`;

    const ym = new Date().toISOString().slice(0, 7);
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
        <span class="meta"><span class="d">${fmtDate(a.날짜)}</span><span class="p">${a.프로그램 || ''} · ${a.장소 || ''}</span></span>
        ${badge}
      </li>`;
    }).join('');
  } catch (e) {
    $('dash-name').innerHTML = `<b>${hakbun || ''}</b> 님`;
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
  try {
    const res = sheetMode === 'in' ? await checkIn(code) : await checkOut(code);
    if (!res || res.ok === false) { toast((res && res.msg) || '코드를 다시 확인해주세요', 'err'); return; }
    buzz(18);
    if (sheetMode === 'in') {
      toast(res.already ? '이미 입실했어요' : `입실 완료 · ${res.장소 || ''}`.trim(), 'ok');
    } else {
      toast(res.already ? '이미 퇴실했어요' : '퇴실 완료! 오늘도 수고했어요', 'ok');
    }
    closeSheet();
    await renderDash(await currentUser());
  } catch (e) {
    toast('처리 실패: ' + (e.message || '오류'), 'err');
  } finally {
    sheetBusy = false; btn.disabled = false; btn.textContent = '확인';
  }
}

async function doLogout() { await logout(); $('login-pin').value = ''; show('view-login'); }

// ── 바인딩 ──
window.addEventListener('DOMContentLoaded', () => {
  $('login-btn').addEventListener('click', doLogin);
  $('login-pin').addEventListener('keydown', (e) => { if (e.key === 'Enter') doLogin(); });
  $('login-hakbun').addEventListener('keydown', (e) => { if (e.key === 'Enter') $('login-pin').focus(); });
  $('pin-btn').addEventListener('click', doChangePin);
  $('pin-new2').addEventListener('keydown', (e) => { if (e.key === 'Enter') doChangePin(); });
  $('dash-logout').addEventListener('click', doLogout);
  $('btn-checkin').addEventListener('click', () => openSheet('in'));
  $('btn-checkout').addEventListener('click', () => openSheet('out'));
  $('code-submit').addEventListener('click', submitCode);
  $('code-cancel').addEventListener('click', closeSheet);
  $('code-input').addEventListener('keydown', (e) => { if (e.key === 'Enter') submitCode(); });
  $('sheet-bg').addEventListener('click', (e) => { if (e.target === $('sheet-bg')) closeSheet(); });
  boot();
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
});
