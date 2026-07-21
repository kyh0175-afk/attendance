// 코스모스 출석 v3 — Supabase 클라이언트 + Auth + 데이터 액세스(DAL)
// supabase-js는 index.html에서 CDN으로 로드 → window.supabase 로 접근.
import { SUPABASE_URL, SUPABASE_KEY, EMAIL_DOMAIN } from './config.js';

let _client = null;
export function sb() {
  if (!_client) {
    if (!window.supabase || !window.supabase.createClient) {
      throw new Error('Supabase 라이브러리 로드 실패 (네트워크 확인)');
    }
    _client = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
      auth: {
        persistSession: true,        // 로그인 유지 (앱 열면 자동 로그인)
        autoRefreshToken: true,
        storageKey: 'cosmos_v3_auth',
      },
    });
  }
  return _client;
}

// ── Auth ──
export const emailForHakbun = (h) => `${String(h).trim()}@${EMAIL_DOMAIN}`.toLowerCase();

export async function login(hakbun, pin) {
  const { data, error } = await sb().auth.signInWithPassword({
    email: emailForHakbun(hakbun),
    password: String(pin),
  });
  if (error) throw error;
  return data;
}

export async function currentUser() {
  const { data } = await sb().auth.getUser();
  return data ? data.user : null;
}

export async function logout() {
  await sb().auth.signOut();
}

export function hakbunOf(user) {
  if (!user) return null;
  return (user.user_metadata && user.user_metadata.hakbun) || (user.email || '').split('@')[0] || null;
}

export function mustChangePin(user) {
  return !!(user && user.user_metadata && user.user_metadata.must_change_pin);
}

export async function changePin(newPin) {
  const { error } = await sb().auth.updateUser({
    password: String(newPin),
    data: { must_change_pin: false },
  });
  if (error) throw error;
}

// ── 입실 / 퇴실 (코드 기반) ──
export async function checkIn(code) {
  const { data, error } = await sb().rpc('check_in', { p_code: String(code).trim() });
  if (error) throw error;
  return data; // { ok, already?, msg?, 프로그램?, 장소? }
}
export async function checkOut(code) {
  const { data, error } = await sb().rpc('check_out', { p_code: String(code).trim() });
  if (error) throw error;
  return data; // { ok, already?, msg? }
}

// ── DAL (학생 본인 데이터 — RLS가 본인 학번 행으로 제한) ──
export async function myProfile() {
  const { data, error } = await sb().from('students').select('*').eq('활성', true);
  if (error) throw error;
  return data || [];
}

export async function myAttendance(days) {
  let q = sb().from('attendance').select('*').order('날짜', { ascending: false });
  if (days) {
    const since = new Date(Date.now() - days * 864e5).toISOString().slice(0, 10);
    q = q.gte('날짜', since);
  }
  const { data, error } = await q;
  if (error) throw error;
  return data || [];
}
