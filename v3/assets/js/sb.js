// 코스모스 출석 v3 — Supabase 클라이언트 + Auth + 데이터 액세스(DAL)
// supabase-js는 index.html에서 CDN으로 로드 → window.supabase 로 접근.
import { SUPABASE_URL, SUPABASE_KEY, EMAIL_DOMAIN } from './config.js';

// HTML 이스케이프 — DB에 저장된 이름/프로그램/장소 등을 innerHTML에 넣기 전 반드시 적용.
// (관리자 엑셀 업로드 등으로 악성 문자열이 저장될 수 있으므로 렌더 시점에서 방어)
export const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// ── KST 날짜 헬퍼 ──
// ★ 브라우저 로컬 TZ나 UTC에 의존하면 안 된다. attendance.날짜는 전부 KST 기준이라
//   toISOString()(UTC)을 쓰면 매월 1일 KST 00:00~09:00에 전월로 집계된다.
const _kstFmt = new Intl.DateTimeFormat('en-CA', {
  timeZone: 'Asia/Seoul', year: 'numeric', month: '2-digit', day: '2-digit',
});
export const todayKST = (d) => _kstFmt.format(d || new Date());        // 'YYYY-MM-DD'
export const monthKST = (d) => todayKST(d).slice(0, 7);               // 'YYYY-MM'
export const daysAgoKST = (n) => todayKST(new Date(Date.now() - n * 864e5));

// ── 인증 만료 판별 ──
// 토큰이 만료·무효화되면 PostgREST가 401(PGRST301) 또는 JWT 관련 메시지를 돌려준다.
// 이 경우엔 '일시적 오류'가 아니라 재로그인이 필요한 상태이므로 호출측에서 구분해야 한다.
export function isAuthError(e) {
  if (!e) return false;
  const msg = String(e.message || '');
  const code = String(e.code || '');
  const status = String(e.status || '');
  return code === 'PGRST301' || status === '401'
    || /jwt|invalid token|token is expired|not authenticated|session (from session_id )?(is )?(expired|missing)|refresh token/i.test(msg);
}

// SIGNED_OUT(리프레시 토큰 무효화 포함) 감지 — 페이지에서 로그인 화면으로 되돌리는 용도.
export function onSignedOut(cb) {
  try { sb().auth.onAuthStateChange((event) => { if (event === 'SIGNED_OUT') cb(); }); }
  catch (_) { /* 라이브러리 로드 실패 등 — 무시 */ }
}

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
// ★ 네트워크 오류를 false로 삼키면 "교사 계정이 아니에요"로 둔갑해 정상 로그인을 강제 로그아웃시킨다.
//   판정 실패는 반드시 throw — 호출측이 '권한 없음'과 '연결 실패'를 구분하게 한다.
export async function isStaff() {
  const { data, error } = await sb().rpc('is_staff');
  if (error) throw error;
  return data === true;
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
    .select('학번,이름,원래시각,퇴실시각,상태,메모').eq('세션id', sessionId)
    .order('원래시각', { ascending: true });
  if (error) throw error;
  return data || [];
}
// 교사 수동 출석 (오프라인·코드 불가 대비) — is_staff 게이트 RPC
export async function manualAttendance(sessionId, hakbun) {
  const { data, error } = await sb().rpc('staff_manual_attendance', {
    p_session_id: String(sessionId), p_hakbun: String(hakbun).trim(),
  });
  if (error) throw error;
  return data; // { ok, id?, name?, already? }
}

// ── 관리자(admin) — RLS: staff 전체 읽기 / 쓰기는 is_admin() 게이트 RPC ──
// is_admin(): true/false = 판정 결과, null = 함수 미배포(마이그레이션 전 — 호출측에서 폴백 판단)
export async function isAdmin() {
  const { data, error } = await sb().rpc('is_admin');
  if (error) {
    if (error.code === 'PGRST202') return null;   // 함수 미배포 — 폴백 판정
    throw error;                                   // 네트워크·권한 오류는 호출측에서 구분
  }
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

// ── 관리자 CRUD (w3_crud_migration.sql — 전부 is_admin 게이트 RPC) ──
const adminRpc = async (fn, params) => {
  const { data, error } = await sb().rpc(fn, params);
  if (error) throw error;
  return data;
};
export const upsertStudent = (hakbun, program, name, room, days) =>
  adminRpc('admin_upsert_student_v3', { p_hakbun: String(hakbun), p_program: program, p_name: name, p_room: room, p_days: days });
export const bulkUpsertStudents = (list) =>
  adminRpc('admin_bulk_upsert_students_v3', { p_students: list });
export const setStudentProgramActive = (hakbun, program, active) =>
  adminRpc('admin_set_student_active_program_v3', { p_hakbun: String(hakbun), p_program: program, p_active: !!active });
export const deleteStudent = (hakbun, program, deleteAttendance) =>
  adminRpc('admin_delete_student_v3', { p_hakbun: String(hakbun), p_program: program || null, p_delete_attendance: !!deleteAttendance });
export const addLateAttendance = (sessionId, hakbun) =>
  adminRpc('admin_add_attendance_v3', { p_session_id: String(sessionId), p_hakbun: String(hakbun) });
export const setAttendanceStatus = (id, status) =>
  adminRpc('admin_update_attendance_status_v3', { p_id: id, p_status: status });
export const deleteAttendance = (id) =>
  adminRpc('admin_delete_attendance_v3', { p_id: id });
export const deleteSession = (sessionId, deleteAttendance = true) =>
  adminRpc('admin_delete_session_v3', { p_session_id: String(sessionId), p_delete_attendance: !!deleteAttendance });

export async function sessionsByDate(date) {
  const { data, error } = await sb().from('sessions').select('*').eq('날짜', date).order('시작시각', { ascending: true });
  if (error) throw error;
  return data || [];
}
export async function attendanceBySession(sessionId) {
  const { data, error } = await sb().from('attendance').select('*')
    .eq('세션id', String(sessionId)).order('원래시각', { ascending: true });
  if (error) throw error;
  return data || [];
}
// (학번×프로그램)별 첫 출석일 맵 (출석률 분모 보정용 — 전 기간 1회 스캔 후 캐시)
// ★ 프로그램별로 키를 나눠야 다중 프로그램 학생의 출석률이 정확하다 (전역 최소일이면
//   나중에 등록한 프로그램의 대상일이 등록 이전까지 소급돼 출석률이 과소 표시됨).
export const firstAttendanceDates = async () => {
  const rows = await fetchAllPaged(() => sb().from('attendance').select('학번,프로그램,날짜').order('id'));
  const map = new Map();   // '학번|프로그램' → 최소 날짜
  for (const r of rows) {
    if (!r.날짜) continue;
    const k = `${r.학번}|${r.프로그램}`;
    if (!map.has(k) || r.날짜 < map.get(k)) map.set(k, r.날짜);
  }
  return map;
};

// ── DAL (학생 본인 데이터 — RLS가 본인 학번 행으로 제한) ──
export async function myProfile() {
  const { data, error } = await sb().from('students').select('*').eq('활성', true);
  if (error) throw error;
  return data || [];
}

export async function myAttendance(days) {
  let q = sb().from('attendance').select('*').order('날짜', { ascending: false });
  if (days) q = q.gte('날짜', daysAgoKST(days));   // KST 기준 (UTC면 하루 밀림)
  const { data, error } = await q;
  if (error) throw error;
  return data || [];
}
