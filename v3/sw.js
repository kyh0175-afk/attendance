// 코스모스 출석 v3 — 서비스워커 (앱 셸 캐시)
// 목적: 학교 와이파이 블립에도 앱 껍데기 즉시 로딩. Supabase API 응답은 캐시하지 않음(항상 네트워크).
const CACHE = 'cosmos-v3-shell-v4';
// ★ 스코프가 /v3/ 전체라 교사·관리자 페이지 요청도 이 워커가 가로챈다.
//   그 페이지들을 셸에 넣지 않으면 오프라인 폴백이 학생 화면으로 떨어진다.
const SHELL = [
  './',
  './index.html',
  './teacher.html',
  './admin.html',
  './assets/js/config.js',
  './assets/js/sb.js',
  './assets/js/student.js',
  './assets/js/teacher.js',
  './assets/js/admin.js',
  './manifest.webmanifest',
  './icon-192.png',
];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  // Supabase(외부 API·인증)는 항상 네트워크 — 캐시 금지
  if (url.origin !== self.location.origin || url.hostname.endsWith('supabase.co')) return;
  if (e.request.method !== 'GET') return;
  // 앱 셸: 네트워크 우선, 실패 시 캐시 폴백
  e.respondWith(
    fetch(e.request).then((res) => {
      // ★ 404·5xx도 캐시에 들어가면 배포 중 오류 페이지가 앱 대신 서빙된다
      if (res && res.ok) {
        const copy = res.clone();
        caches.open(CACHE).then((c) => c.put(e.request, copy)).catch(() => {});
      }
      return res;
    // ★ 폴백은 '요청한 그 URL'로만. index.html로 넘기면 teacher.html 주소에 학생 화면이 뜬다.
    }).catch(() => caches.match(e.request))
  );
});
