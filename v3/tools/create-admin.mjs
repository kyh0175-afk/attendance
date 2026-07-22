// 코스모스 출석 v3 — 관리자 계정 생성/초기화 (로컬 실행 전용)
//
// ▶ 사용:  node create-admin.mjs
//    - admin@staff.yubongsystem.com 계정을 만들고 staff 테이블에 role='admin'으로 등록한다.
//    - 이미 있으면 임시 PIN만 다시 발급한다(관리자 PIN 분실 시에도 이걸 실행).
//    - 임시 PIN이 터미널에 표시된다 → admin.html 첫 로그인 때 새 PIN 설정이 강제된다.
// ▶ service_role 키 필요(환경변수 SUPABASE_SERVICE_ROLE_KEY) — README.md 참고.
// ▶ ⚠️ 가급적 별도 터미널에서 실행(임시 PIN이 화면에 표시되므로).

import { createClient } from '@supabase/supabase-js';
import { randomInt } from 'node:crypto';

const URL = process.env.SUPABASE_URL || 'https://rxsmmwqekrtbstcjbagj.supabase.co';
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const ADMIN_EMAIL = 'admin@staff.yubongsystem.com';

if (!KEY) { console.error('❌ 환경변수 SUPABASE_SERVICE_ROLE_KEY 가 없습니다. README.md 참고.'); process.exit(1); }
const sb = createClient(URL, KEY, { auth: { persistSession: false, autoRefreshToken: false } });

const tempPin = String(randomInt(100000, 1000000));   // 6자리

// 1) 계정 생성 또는 임시 PIN 재발급
let adminId = null;
{
  const { data, error } = await sb.auth.admin.createUser({
    email: ADMIN_EMAIL,
    password: tempPin,
    email_confirm: true,
    user_metadata: { name: '관리자', must_change_pin: true },
  });
  if (error && /already|exists/i.test(error.message)) {
    let found = null;
    for (let page = 1; ; page++) {
      const { data: d, error: e } = await sb.auth.admin.listUsers({ page, perPage: 1000 });
      if (e) { console.error('❌ 계정 조회 실패:', e.message); process.exit(1); }
      found = d.users.find((u) => (u.email || '').toLowerCase() === ADMIN_EMAIL) || found;
      if (found || d.users.length < 1000) break;
    }
    if (!found) { console.error('❌ 기존 계정을 찾지 못했습니다.'); process.exit(1); }
    adminId = found.id;
    const { error: e2 } = await sb.auth.admin.updateUserById(adminId, {
      password: tempPin,
      user_metadata: { ...found.user_metadata, must_change_pin: true },
    });
    if (e2) { console.error('❌ PIN 재발급 실패:', e2.message); process.exit(1); }
    console.log('기존 관리자 계정 → 임시 PIN 재발급.');
  } else if (error) {
    console.error('❌ 계정 생성 실패:', error.message); process.exit(1);
  } else {
    adminId = data.user.id;
    console.log('관리자 계정 신규 생성.');
  }
}

// 2) staff 테이블에 role='admin' 등록 (service_role은 RLS 우회)
{
  const { data: rows, error } = await sb.from('staff').select('user_id,role').eq('user_id', adminId);
  if (error) { console.error('❌ staff 조회 실패:', error.message); process.exit(1); }
  if (rows.length) {
    if (rows[0].role !== 'admin') {
      const { error: e } = await sb.from('staff').update({ role: 'admin' }).eq('user_id', adminId);
      if (e) { console.error('❌ staff role 갱신 실패:', e.message); process.exit(1); }
      console.log('staff role → admin 으로 갱신.');
    } else console.log('staff 등록 확인 (role=admin).');
  } else {
    const { error: e } = await sb.from('staff').insert({ user_id: adminId, role: 'admin', 이름: '관리자' });
    if (e) { console.error('❌ staff 등록 실패:', e.message); process.exit(1); }
    console.log('staff 등록 완료 (role=admin).');
  }
}

console.log(`\n✅ 완료 — admin.html 에서 아래 임시 PIN으로 로그인하세요.`);
console.log(`   임시 PIN: ${tempPin}`);
console.log('   첫 로그인 시 새 PIN 설정이 강제됩니다. 이 터미널 기록은 닫아주세요.');
