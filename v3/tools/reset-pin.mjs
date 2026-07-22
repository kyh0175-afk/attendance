// 코스모스 출석 v3 — 학생 PIN 초기화 (로컬 실행 전용)
//
// ▶ 사용:  node reset-pin.mjs 30610            → 임시 PIN 자동 발급(4자리)
//          node reset-pin.mjs 30610 --pin 1234  → 지정 PIN으로 초기화
//          node reset-pin.mjs teacher@staff.yubongsystem.com --pin 123456  → 이메일 직접 지정(교사 계정 등)
//    초기화하면 must_change_pin=true 가 걸려 첫 로그인 때 새 PIN 설정이 강제된다.
// ▶ service_role 키 필요(환경변수 SUPABASE_SERVICE_ROLE_KEY) — README.md 참고.

import { createClient } from '@supabase/supabase-js';
import { randomInt } from 'node:crypto';

const URL = process.env.SUPABASE_URL || 'https://rxsmmwqekrtbstcjbagj.supabase.co';
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const EMAIL_DOMAIN = 'st.yubongsystem.com';

const args = process.argv.slice(2);
const target = args.find((a) => !a.startsWith('--'));
const pinIdx = args.indexOf('--pin');
const givenPin = pinIdx >= 0 ? args[pinIdx + 1] : null;

if (!KEY) { console.error('❌ 환경변수 SUPABASE_SERVICE_ROLE_KEY 가 없습니다. README.md 참고.'); process.exit(1); }
if (!target) { console.error('사용법: node reset-pin.mjs <학번 또는 이메일> [--pin 새PIN]'); process.exit(1); }
if (givenPin && !/^\d{4,12}$/.test(givenPin)) { console.error('❌ PIN은 숫자 4~12자리.'); process.exit(1); }

const email = target.includes('@') ? target.toLowerCase() : `${target}@${EMAIL_DOMAIN}`.toLowerCase();
const newPin = givenPin || String(randomInt(1000, 10000));   // 4자리

const sb = createClient(URL, KEY, { auth: { persistSession: false, autoRefreshToken: false } });

// 대상 계정 찾기
let user = null;
for (let page = 1; ; page++) {
  const { data, error } = await sb.auth.admin.listUsers({ page, perPage: 1000 });
  if (error) { console.error('❌ 계정 조회 실패:', error.message); process.exit(1); }
  user = data.users.find((u) => (u.email || '').toLowerCase() === email) || user;
  if (user || data.users.length < 1000) break;
}
if (!user) { console.error(`❌ 계정 없음: ${email}\n   (계정 일괄 생성을 먼저 실행했는지 확인)`); process.exit(1); }

const { error } = await sb.auth.admin.updateUserById(user.id, {
  password: newPin,
  user_metadata: { ...user.user_metadata, must_change_pin: true },
});
if (error) { console.error('❌ 초기화 실패:', error.message); process.exit(1); }

const name = (user.user_metadata && user.user_metadata.name) || '';
console.log(`✅ ${target} ${name} — PIN 초기화 완료.`);
console.log(`   임시 PIN: ${newPin}`);
console.log('   본인에게 전달하세요. 첫 로그인 때 새 PIN 설정이 강제됩니다.');
