// 코스모스 출석 v3 — 학생 Auth 계정 벌크 생성 (로컬 실행 전용)
//
// ▶ 실행 방법은 같은 폴더의 README.md 참고.
// ▶ service_role 키는 코드에 넣지 말 것 — 환경변수(SUPABASE_SERVICE_ROLE_KEY)로만.
//   이 키는 RLS를 전부 우회하는 관리자 키이므로 절대 커밋/공유 금지.
//
// 동작: students(활성) 명단의 학번마다 Auth 계정 생성
//   - 이메일: {학번}@st.yubongsystem.com
//   - 비밀번호(초기 PIN): 아래 PIN_STRATEGY 참고 (기본 = 학번 그대로)
//   - user_metadata: { hakbun, name, must_change_pin: true }  ← 첫 로그인 시 PIN 변경 강제
//   - 이미 있는 계정은 건너뜀 (idempotent — 여러 번 돌려도 안전)

import { createClient } from '@supabase/supabase-js';

const URL = process.env.SUPABASE_URL || 'https://rxsmmwqekrtbstcjbagj.supabase.co';
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const EMAIL_DOMAIN = 'st.yubongsystem.com';
const DRY_RUN = process.argv.includes('--dry');

// ── 초기 PIN 전략 ──────────────────────────────────────────────
// 기본: 학번 그대로 (학생이 이미 아는 값, 첫 로그인 시 강제 변경).
//   ⚠️ 트레이드오프: 반 친구가 내 학번을 알면 내가 로그인하기 전에 먼저
//      들어가 PIN을 바꿔버릴 수 있음 → 관리자 PIN 초기화로 복구.
//      더 안전하게 하려면 무작위 PIN 발급 후 종이로 배부(아래 randomPin 참고).
const PIN_STRATEGY = (hakbun) => String(hakbun);
// const PIN_STRATEGY = (hakbun) => String(Math.floor(1000 + Math.random() * 9000)); // 무작위 4자리(배부 필요)
// ───────────────────────────────────────────────────────────────

if (!KEY) {
  console.error('❌ 환경변수 SUPABASE_SERVICE_ROLE_KEY 가 없습니다. README.md 참고.');
  process.exit(1);
}

const sb = createClient(URL, KEY, { auth: { persistSession: false, autoRefreshToken: false } });

// 1) 명단(활성) — 학번 기준 중복 제거
const { data: students, error } = await sb.from('students').select('학번,이름').eq('활성', true);
if (error) { console.error('❌ 명단 조회 실패:', error.message); process.exit(1); }
const roster = [...new Map(students.map((s) => [String(s.학번), s.이름])).entries()];
console.log(`활성 학생 ${roster.length}명 (학번 기준 중복 제거).`);

// 2) 기존 Auth 계정 (페이지네이션)
const existing = new Set();
for (let page = 1; ; page++) {
  const { data, error: e } = await sb.auth.admin.listUsers({ page, perPage: 1000 });
  if (e) { console.error('❌ 기존 계정 조회 실패:', e.message); process.exit(1); }
  data.users.forEach((u) => u.email && existing.add(u.email.toLowerCase()));
  if (data.users.length < 1000) break;
}
console.log(`기존 Auth 계정 ${existing.size}개 확인.`);

// 3) 생성
let created = 0, skipped = 0, failed = 0;
for (const [hakbun, name] of roster) {
  const email = `${hakbun}@${EMAIL_DOMAIN}`.toLowerCase();
  if (existing.has(email)) { skipped++; continue; }
  if (DRY_RUN) { created++; continue; }
  const { error: e } = await sb.auth.admin.createUser({
    email,
    password: PIN_STRATEGY(hakbun),
    email_confirm: true,
    user_metadata: { hakbun, name, must_change_pin: true },
  });
  if (e) { failed++; console.error(`  ❌ ${hakbun}: ${e.message}`); }
  else { created++; if (created % 50 === 0) console.log(`  …${created}개 생성`); }
}

console.log(`\n완료 — 생성 ${created} · 건너뜀(기존) ${skipped} · 실패 ${failed}${DRY_RUN ? '   [DRY RUN — 실제 생성 안 함]' : ''}`);
if (!DRY_RUN && created > 0) {
  console.log('학생 안내: v3 접속 → 학번 + 초기 PIN(=학번) 로그인 → 새 PIN 설정.');
}
