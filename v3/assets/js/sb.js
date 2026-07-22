// 코스모스 출석 v3 — Supabase 클라이언트 + Auth + 데이터 액세스(DAL)
// supabase-js는 index.html에서 CDN으로 로드 → window.supabase 로 접근.
import { SUPABASE_URL, SUPABASE_KEY, EMAIL_DOMAIN } from './config.js';

let _client = null;
let _storageKey = 'cosmos_v3_auth';   // 학생 기본. 교사 페이지는 별도 키로 분리(같은 브라우저 공존).
// ★ sb() 최초 호출 전에 불러야 적용됨 (페이지 모듈 최상단에서 호출).
export function setAuthStorageKey(key) { _storageKey = key; }

export function sb() {
  if (!_client) {
    if (!window.supabase || !window.supabase.createClient) {
      throw new Error('Supabase 라이브러리 로드 실패 (네트워크 확인)');
    }
    _client = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
      auth: {
        persistSession: true,        // 로그인 유지 (앱 열면 자동 로그인)
        autoRefreshToken: true,
        storageKey: _storageKey,
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

// ── 교사(staff) ──
export async function isStaff() {
  try { const { data, error } = await sb().rpc('is_staff'); if (error) return false; return data === true; }
  catch (_) { return false; }
}
export async function createSession(program, room, teacher) {
  const { data, error } = await sb().rpc('create_v3_session', { p_program: program, p_room: room, p_teacher: teacher });
  if (error) throw error;
  return data; // { session_id, entry_code }
}
export async function issueExitCode(sessionId) {
  const { data, error } = await sb().rpc('issue_exit_code', { p_session_id: sessionId });
  if (error) throw error;
  return data; // { code, expires_at }
}
export async function finalizeSession(sessionId) {
  const { data, error } = await sb().rpc('finalize_session', { p_session_id: sessionId });
  if (error) throw error;
  return data; // { ok, missing }
}
export async function sessionRoster(sessionId) {
  const { data, error } = await sb().from('attendance')
    .select('학번,이름,원래시각,퇴실시각,상태').eq('세션id', sessionId)
    .order('원래시각', { ascending: true });
  if (error) throw error;
  return data || [];
}

// ── 관리자(admin) — RLS: staff 전체 읽기 / 쓰기는 is_admin() 게이트 RPC ──
// is_admin(): true/false = 판정 결과, null = 함수 미배포(마이그레이션 전 — 호출측에서 폴백 판단)
export async function isAdmin() {
  const { data, error } = await sb().rpc('is_admin');
  if (error) return error.code === 'PGRST202' ? null : false;
  return data === true;
}

// PostgREST 1,000행 캡 우회 — build()가 매번 새 쿼리 빌더를 반환해야 한다.
// ⚠️ 정렬이 결정적이어야 페이지 경계가 안 깨진다(고유 tiebreaker 포함 필수).
export async function fetchAllPaged(build, pageSize = 1000, hardCap = 200000) {
  const out = [];
  for (let from = 0; from < hardCap; from += pageSize) {
    const { data, error } = await build().range(from, from + pageSize - 1);
    if (error) throw error;
    out.push(...(data || []));
    if (!data || data.length < pageSize) break;
  }
  return out;
}

export const allStudents = () =>
  fetchAllPaged(() => sb().from('students').select('*').order('학번').order('프로그램').order('생성일시'));

export const allSessions = () =>
  fetchAllPaged(() => sb().from('sessions').select('*').order('id', { ascending: false }));

export async function activeSessions() {
  const { data, error } = await sb().from('sessions').select('*').eq('활성', true).order('id', { ascending: false });
  if (error) throw error;
  return data || [];
}

export const attendanceInRange = (from, to, program) =>
  fetchAllPaged(() => {
    let q = sb().from('attendance').select('*').order('날짜', { ascending: false }).order('id', { ascending: false });
    if (from) q = q.gte('날짜', from);
    if (to) q = q.lte('날짜', to);
    if (program) q = q.eq('프로그램', program);
    return q;
  });

// 학생 전체 활성/비활성 (전 프로그램 행 일괄) — admin 전용 RPC (w3_migration.sql)
export async function setStudentActive(hakbun, active) {
  const { data, error } = await sb().rpc('admin_set_student_active_v3', {
    p_hakbun: String(hakbun), p_active: !!active,
  });
  if (error) throw error;
  return data; // { ok, updated }
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
