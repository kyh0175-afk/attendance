// 코스모스 출석 v3 — 학생 페이지 컨트롤러 (로그인 · PIN변경 · 대시보드)
import { login, logout, currentUser, hakbunOf, mustChangePin, changePin, myProfile, myAttendance } from './sb.js';

const $ = (id) => document.getElementById(id);
const show = (id) => { for (const v of ['view-loading', 'view-login', 'view-pin', 'view-dash']) $(v).style.display = (v === id ? 'block' : 'none'); };
const toast = (msg, ok) => {
  const t = $('toast'); t.textContent = msg; t.className = 'toast on' + (ok ? ' ok' : ' err');
  setTimeout(() => { t.className = 'toast'; }, 2600);
};

// ── 부팅: 세션 확인 → 화면 분기 ──
async function boot() {
  show('view-loading');
  let user;
  try { user = await currentUser(); }
  catch (e) { show('view-login'); return; }
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
    const user = await currentUser();
    if (mustChangePin(user)) { show('view-pin'); }
    else { await renderDash(user); }
  } catch (e) {
    toast(/Invalid login/i.test(e.message || '') ? '학번 또는 PIN이 올바르지 않아요' : ('로그인 실패: ' + (e.message || '오류')));
  } finally {
    btn.disabled = false; btn.textContent = '로그인';
  }
}

// ── PIN 변경 (최초 로그인 필수) ──
async function doChangePin() {
  const p1 = $('pin-new').value.trim();
  const p2 = $('pin-new2').value.trim();
  const btn = $('pin-btn');
  if (!/^\d{4,6}$/.test(p1)) { toast('새 PIN은 숫자 4~6자리'); return; }
  if (p1 !== p2) { toast('두 PIN이 일치하지 않아요'); return; }
  btn.disabled = true; btn.textContent = '저장 중…';
  try {
    await changePin(p1);
    toast('PIN이 설정됐어요', true);
    const user = await currentUser();
    await renderDash(user);
  } catch (e) {
    toast('변경 실패: ' + (e.message || '오류'));
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
    $('dash-name').textContent = name ? (name + ' 님') : (hakbun + ' 님');

    const total = att.length;
    const thisMonth = att.filter(a => (a.날짜 || '').slice(0, 7) === new Date().toISOString().slice(0, 7)).length;
    $('stat-total').textContent = total;
    $('stat-month').textContent = thisMonth;

    const list = $('dash-list');
    if (!att.length) { list.innerHTML = '<li class="empty">아직 출석 기록이 없어요.</li>'; return; }
    list.innerHTML = att.slice(0, 30).map(a => {
      const out = a.퇴실시각 ? '<span class="badge ok">퇴실 완료</span>'
        : (a.상태 === '퇴실미확인' ? '<span class="badge warn">퇴실미확인</span>' : '');
      return `<li><span class="d">${a.날짜 || ''}</span><span class="p">${a.프로그램 || ''} · ${a.장소 || ''}</span>${out}</li>`;
    }).join('');
  } catch (e) {
    $('dash-name').textContent = (hakbun || '') + ' 님';
    toast('기록 조회 실패: ' + (e.message || '오류'));
  }
}

async function doLogout() { await logout(); $('login-pin').value = ''; show('view-login'); }

// ── 바인딩 ──
window.addEventListener('DOMContentLoaded', () => {
  $('login-btn').addEventListener('click', doLogin);
  $('login-pin').addEventListener('keydown', (e) => { if (e.key === 'Enter') doLogin(); });
  $('pin-btn').addEventListener('click', doChangePin);
  $('dash-logout').addEventListener('click', doLogout);
  boot();
  // 서비스워커 등록 (오프라인 앱 셸)
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
});
