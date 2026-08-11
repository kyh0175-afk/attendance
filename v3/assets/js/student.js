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

const VIEWS = ['view-loading', 'view-start', 'view-role', 'view-login', 'view-pin', 'view-dash'];
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
  const wantStart = /[?&]start\b/.test(location.search);   // QR 진입
  let user;
  // 비로그인 첫 진입은 역할 선택(view-role)으로. 세션 만료 복귀(bounceIfExpired)·로그아웃은
  // 역할이 자명하므로 기존대로 view-login 직행 — 이 분기만 다르다.
  try { user = await currentUser(); } catch (e) { show(wantStart ? 'view-start' : 'view-role'); if (wantStart) startWizard(); return; }
  if (!user) { if (wantStart) startWizard(); else show('view-role'); return; }
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
  if (user) { await renderDash(user); maybeShowUsageGuide(); }
  else { toast('새 PIN으로 다시 로그인해주세요', 'ok'); show('view-login'); }
}

// ── 대시보드 ──
async function renderDash(user) {
  show('view-dash');
  refreshInstallBar();
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

// ── 앱 설치 (홈 화면에 추가) ──
// v3는 이미 PWA(manifest + 서비스워커)라 설치 자체는 되는데, 학생이 방법을 몰라서
// 안 하는 게 문제였다. 안드로이드는 브라우저가 주는 설치 프롬프트를 그대로 띄우고,
// iOS는 그런 API가 없어서 '공유 → 홈 화면에 추가'를 그림 없이도 따라할 수 있게 안내한다.
const INSTALL_SNOOZE_KEY = 'cosmos_v3_install_snooze';
const INSTALL_SHOWN_KEY = 'cosmos_v3_install_shown';
const INSTALL_SNOOZE_DAYS = 7;
let deferredPrompt = null;

function isStandalone() {
  try {
    if (window.navigator.standalone === true) return true;        // iOS Safari
    return matchMedia('(display-mode: standalone)').matches;      // Android · 데스크톱
  } catch (_) { return false; }
}
const isIOS = () => /iphone|ipad|ipod/i.test(navigator.userAgent)
  || (/mac/i.test(navigator.platform || '') && navigator.maxTouchPoints > 1);   // iPadOS
const isSamsung = () => /samsungbrowser/i.test(navigator.userAgent);

function installSnoozed() {
  try {
    const t = Number(localStorage.getItem(INSTALL_SNOOZE_KEY) || 0);
    return !!t && (Date.now() - t) < INSTALL_SNOOZE_DAYS * 864e5;
  } catch (_) { return false; }
}
function snoozeInstall() {
  try { localStorage.setItem(INSTALL_SNOOZE_KEY, String(Date.now())); } catch (_) {}
}
function refreshInstallBar() {
  const bar = $('install-bar');
  if (!bar) return;
  const show = !isStandalone() && !installSnoozed();
  bar.classList.toggle('on', show);
}

// 브라우저별 설치 경로 안내. os를 넘기면 그 기준으로, 안 넘기면 자동 감지.
function installGuide(os) {
  let target = os || (isIOS() ? 'ios' : 'and');
  if (target === 'and' && isSamsung()) target = 'samsung';
  if (target === 'ios') {
    return {
      sub: 'Safari에서 아래 순서대로 하면 앱처럼 쓸 수 있어요',
      steps: [
        '화면 <span class="k">아래쪽 공유 버튼</span>을 눌러요 (네모에 화살표 ↑)',
        '목록을 내려서 <span class="k">홈 화면에 추가</span>를 눌러요',
        '오른쪽 위 <span class="k">추가</span>를 누르면 끝이에요',
      ],
      note: '· 크롬 앱에서 열었다면 Safari로 다시 열어야 이 메뉴가 나와요.<br>· 추가한 뒤에는 학번과 PIN으로 한 번만 다시 로그인하면 계속 유지돼요.',
    };
  }
  if (target === 'samsung') {
    return {
      sub: '삼성 인터넷에서 아래 순서대로 해요',
      steps: [
        '아래쪽 <span class="k">☰</span> 메뉴를 눌러요',
        '<span class="k">현재 페이지 추가</span>를 눌러요',
        '<span class="k">홈 화면</span>을 골라요',
      ],
      note: '· 홈 화면에 코스모스 아이콘이 생기면 성공이에요.',
    };
  }
  return {
    sub: '브라우저 메뉴에서 아래 순서대로 해요',
    steps: [
      '오른쪽 위 <span class="k">⋮</span> 메뉴를 눌러요',
      '<span class="k">앱 설치</span> 또는 <span class="k">홈 화면에 추가</span>를 눌러요',
      '<span class="k">설치</span>를 누르면 끝이에요',
    ],
    note: '· 메뉴에 안 보이면 주소창 오른쪽의 설치 아이콘을 확인해보세요.',
  };
}

function openInstallSheet(os) {
  const g = installGuide(os);
  $('install-title').textContent = '홈 화면에 추가하기';
  $('install-sub').textContent = g.sub;
  $('install-steps').innerHTML = g.steps
    .map((s, i) => `<li><span class="n">${i + 1}</span><span>${s}</span></li>`).join('');
  $('install-note').innerHTML = g.note;
  $('install-bg').classList.add('on');
}
function closeInstallSheet() { $('install-bg').classList.remove('on'); }

// 반환값 = 브라우저 프롬프트로 실제 설치까지 끝났는지
async function doInstall(os) {
  // 안드로이드·데스크톱 크롬: 브라우저가 준 프롬프트를 그대로 띄운다
  if (deferredPrompt) {
    const p = deferredPrompt;
    deferredPrompt = null;
    try {
      p.prompt();
      const res = await p.userChoice;
      const ok = !!(res && res.outcome === 'accepted');
      if (ok) { snoozeInstall(); refreshInstallBar(); }
      return ok;
    } catch (_) { /* 실패하면 수동 안내로 폴백 */ }
  }
  openInstallSheet(os);
  return false;
}

// 최초 PIN 설정 직후 한 번만 사용법 안내 (DESIGN 2-1의 안내 지점)
// 설치 안내는 대시보드 배너가 상시 담당하므로 여기서는 '쓰는 법'을 보여준다.
function maybeShowUsageGuide() {
  try {
    if (localStorage.getItem(INSTALL_SHOWN_KEY)) return;
    localStorage.setItem(INSTALL_SHOWN_KEY, '1');
  } catch (_) { return; }
  setTimeout(showUsageGuide, 900);
}

// ── 시작 위저드 (QR로 들어온 학생용) ──
// QR → /v3/?start → 기기 선택 → 설치 → 로그인 안내 순으로 한 단계씩 진행한다.
// ★ 설치 단계를 이 페이지(index.html)에서 진행하는 게 중요하다. 별도 안내 페이지를
//   만들어 거기서 '홈 화면에 추가'를 하면, 구형 iOS는 manifest의 start_url 대신
//   그 페이지 주소를 그대로 저장해 버려 앱 아이콘이 안내 페이지로 열린다.
const WIZ_TITLES = [
  { t: '어떤 폰을 쓰나요?', d: '기기에 따라 방법이 조금 달라요' },
  { t: '앱으로 만들기', d: '홈 화면에 추가하면 다음부터 바로 열려요' },
  { t: '로그인하기', d: '학번과 처음 PIN만 있으면 돼요' },
];
let wizOS = '';

function wizGo(n) {
  for (let i = 0; i < 3; i++) {
    const p = $('w-p' + i);
    if (p) p.classList.toggle('on', i === n);
  }
  const dots = $('w-dots').children;
  for (let i = 0; i < dots.length; i++) dots[i].classList.toggle('on', i <= n);
  $('w-title').textContent = WIZ_TITLES[n].t;
  $('w-desc').textContent = WIZ_TITLES[n].d;
  window.scrollTo(0, 0);
}

function wizPickOS(os) {
  wizOS = os;
  $('w-ios').classList.toggle('on', os === 'ios');
  $('w-and').classList.toggle('on', os === 'and');

  const g = installGuide(os);
  $('w-steps').innerHTML = g.steps
    .map((s, i) => `<li><span class="n">${i + 1}</span><span>${s}</span></li>`).join('');
  $('w-steps-note').innerHTML = g.note;
  // 안드로이드에서 브라우저가 설치 프롬프트를 줄 때만 '앱 설치하기' 버튼이 의미 있다
  $('w-install').style.display = (os === 'and' && deferredPrompt) ? '' : 'none';
  wizGo(1);
}

function startWizard() {
  wizGo(0);
  const guessed = isIOS() ? '아이폰' : '안드로이드';
  $('w-guess').textContent = `이 폰은 ${guessed}으로 보여요. 맞으면 그대로 누르고, 다르면 다른 쪽을 눌러주세요.`;
  show('view-start');
  // 이미 설치한 상태로 들어오면 설치 단계는 건너뛴다
  if (isStandalone()) { wizOS = isIOS() ? 'ios' : 'and'; wizGo(2); }
}

function wizToLogin() {
  show('view-login');
  setTimeout(() => { try { $('login-hakbun').focus(); } catch (_) {} }, 300);
}

// PIN 설정까지 끝낸 학생에게 사용법을 한 번 보여준다
function showUsageGuide() {
  $('install-title').textContent = '이제 이렇게 쓰면 돼요';
  $('install-sub').textContent = '입실과 퇴실, 두 번만 찍으면 끝이에요';
  $('install-steps').innerHTML = [
    '자습실에 도착하면 <span class="k">입실</span> → 칠판의 <b>입실 코드 4자리</b>',
    '끝날 때 <span class="k">퇴실</span> → 선생님이 알려주는 <b>퇴실 코드 4자리</b>',
    '내 출석 기록은 이 화면에서 언제든 볼 수 있어요',
  ].map((s, i) => `<li><span class="n">${i + 1}</span><span>${s}</span></li>`).join('');
  $('install-note').innerHTML = '· 퇴실을 안 찍으면 <b>퇴실미확인</b>으로 남아요. 꼭 찍고 나가주세요.';
  $('install-bg').classList.add('on');
}

// ── 바인딩 ──
window.addEventListener('DOMContentLoaded', () => {
  $('role-student').addEventListener('click', () => { buzz(); show('view-login'); });
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

  // 시작 위저드
  $('w-ios').addEventListener('click', () => wizPickOS('ios'));
  $('w-and').addEventListener('click', () => wizPickOS('and'));
  $('w-install').addEventListener('click', async () => { if (await doInstall(wizOS)) wizGo(2); });
  $('w-next1').addEventListener('click', () => wizGo(2));
  $('w-go-login').addEventListener('click', wizToLogin);
  $('w-skip').addEventListener('click', wizToLogin);

  // 앱 설치
  $('install-go').addEventListener('click', () => doInstall());
  $('install-x').addEventListener('click', () => { snoozeInstall(); refreshInstallBar(); });
  $('install-close').addEventListener('click', closeInstallSheet);
  $('install-bg').addEventListener('click', (e) => { if (e.target === $('install-bg')) closeInstallSheet(); });
  refreshInstallBar();
  // 리프레시 토큰이 무효화되면 supabase-js가 SIGNED_OUT을 발생시킨다 → 로그인 화면으로 복귀
  onSignedOut(() => {
    if (loggingOut) return;                     // 사용자가 직접 로그아웃한 경우는 제외
    toast('로그인이 만료됐어요. 다시 로그인해주세요', 'err');
    show('view-login');
  });
  boot();
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
});

// 안드로이드·데스크톱 크롬이 "설치 가능" 판정을 내리면 여기로 온다.
// 기본 배너를 막아두고, 우리 배너의 [추가] 버튼에서 원하는 타이밍에 띄운다.
window.addEventListener('beforeinstallprompt', (e) => {
  e.preventDefault();
  deferredPrompt = e;
  refreshInstallBar();
});
window.addEventListener('appinstalled', () => {
  deferredPrompt = null;
  snoozeInstall();
  refreshInstallBar();
  closeInstallSheet();
  toast('홈 화면에 추가됐어요', 'ok');
});
