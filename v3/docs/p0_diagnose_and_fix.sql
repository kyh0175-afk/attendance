-- ═══════════════════════════════════════════════════════════════
--  코스모스 v3 — P0 진단 & 패치 (2026-08-01)
--  Supabase 대시보드 → SQL Editor 에 섹션별로 붙여넣어 실행.
--  A는 읽기 전용(진단), B는 변경, C는 덤프용.
-- ═══════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────
-- A. 진단 (읽기 전용 — 아무것도 바꾸지 않음)
-- ───────────────────────────────────────────────────────────────

-- A-1. v3 함수 배포 현황
--  ❌가 하나라도 있으면 그 파일의 마이그레이션이 미적용이다.
--  · is_staff / is_admin                     → w3_migration.sql
--  · admin_*_v3 8종 + staff_manual_attendance → w3_crud_migration.sql
--  · create_v3_session / issue_exit_code / finalize_session / check_in / check_out
--                                             → 레포에 소스 없음(대시보드 전용) — 섹션 C로 덤프할 것
select f.name                                                        as "함수",
       case when p.oid is not null then '✅ 있음' else '❌ 없음' end   as "배포",
       coalesce(pg_get_function_identity_arguments(p.oid), '')       as "인자",
       coalesce(p.prosecdef::text, '')                               as "SECURITY DEFINER"
from (values
  ('is_staff'), ('is_admin'),
  ('create_v3_session'), ('issue_exit_code'), ('finalize_session'),
  ('check_in'), ('check_out'), ('staff_manual_attendance'),
  ('admin_set_student_active_v3'),
  ('admin_upsert_student_v3'), ('admin_bulk_upsert_students_v3'),
  ('admin_set_student_active_program_v3'), ('admin_delete_student_v3'),
  ('admin_add_attendance_v3'), ('admin_update_attendance_status_v3'),
  ('admin_delete_attendance_v3'), ('admin_delete_session_v3')
) as f(name)
left join pg_proc p
       on p.proname = f.name
      and p.pronamespace = 'public'::regnamespace
order by 2, 1;


-- A-2. RLS 정책 현황
--  sessions에 staff 읽기 정책이 없으면 관리자 '기록 탭'이 통째로 빈 화면이 된다
--  (에러가 아니라 0행이라 원인 파악이 어렵다).
select tablename   as "테이블",
       policyname  as "정책",
       cmd         as "대상",
       roles       as "역할"
from pg_policies
where schemaname = 'public'
  and tablename in ('sessions', 'students', 'attendance', 'staff')
order by tablename, policyname;


-- A-3. ★ 테이블 권한(GRANT) + RLS 스위치 — 가장 놓치기 쉬운 항목
--  w3_migration.sql이 sessions에는 정책만 만들고 GRANT를 빠뜨렸다.
--  "authenticated SELECT"가 false면 정책이 있어도 permission denied가 난다.
select t.tablename                                                      as "테이블",
       has_table_privilege('authenticated', 'public.' || t.tablename, 'SELECT') as "authenticated SELECT",
       has_table_privilege('anon',          'public.' || t.tablename, 'SELECT') as "anon SELECT",
       c.relrowsecurity                                                 as "RLS 켜짐"
from pg_tables t
join pg_class c on c.relname = t.tablename and c.relnamespace = 'public'::regnamespace
where t.schemaname = 'public'
  and t.tablename in ('sessions', 'students', 'attendance', 'staff')
order by 1;


-- A-4. 데이터 정합성 빠른 점검
select (select count(*) from public.students)                            as "명단 행",
       (select count(distinct "학번") from public.students)               as "고유 학생",
       (select count(*) from public.students where "활성")                as "활성 등록",
       (select count(*) from public.sessions)                            as "세션",
       (select count(*) from public.sessions where "활성")                as "열린 세션",
       (select count(*) from public.attendance)                          as "출석 행";

-- A-5. 좀비 세션 — 어제 이전인데 아직 열려 있는 세션(자동 마감이 없어 수동 정리 필요)
select "세션id", "날짜", "프로그램", "장소", "담당교사", "시작시각"
from public.sessions
where "활성" = true
  and "날짜" < (now() at time zone 'Asia/Seoul')::date
order by "날짜" desc, "시작시각";


-- ───────────────────────────────────────────────────────────────
-- B. 패치 — A-3에서 sessions의 "authenticated SELECT"가 false일 때만 실행
-- ───────────────────────────────────────────────────────────────

-- ⚠️ RLS 스위치는 건드리지 않는다. v2가 같은 테이블을 anon으로 쓰고 있어
--    enable row level security를 새로 켜면 v2 라이브가 깨질 수 있다.
--    여기서는 authenticated에게 SELECT 권한만 추가한다(정책이 실제 범위를 통제).
grant select on public.sessions to authenticated;

-- 확인
select has_table_privilege('authenticated', 'public.sessions', 'SELECT') as "이제 true여야 함";


-- ───────────────────────────────────────────────────────────────
-- C. 코어 RPC 정의 덤프 — 결과를 v3/docs/core_rpc.sql 로 저장할 것
-- ───────────────────────────────────────────────────────────────

-- ★ create_v3_session / issue_exit_code / finalize_session / check_in / check_out 은
--   현재 대시보드에만 존재하고 레포에 소스가 없다. DB가 유실되면 복원 불가.
--   아래 결과 한 칸을 통째로 복사해 v3/docs/core_rpc.sql 로 커밋한다.
select string_agg(pg_get_functiondef(p.oid), E'\n\n' order by p.proname) as "정의"
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname in (
    'is_staff', 'is_admin',
    'create_v3_session', 'issue_exit_code', 'finalize_session',
    'check_in', 'check_out', 'staff_manual_attendance'
  );

-- (참고) 함수별 EXECUTE 권한 — anon에 열린 게 있으면 회수 대상
select p.proname as "함수",
       has_function_privilege('anon',          p.oid, 'EXECUTE') as "anon",
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as "authenticated"
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and (p.proname like '%_v3' or p.proname in
       ('is_staff','is_admin','check_in','check_out','issue_exit_code',
        'finalize_session','create_v3_session','staff_manual_attendance'))
order by 1;
