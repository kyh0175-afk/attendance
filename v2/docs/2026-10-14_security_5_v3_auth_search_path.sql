-- 2026-10-14 보안 5단계: v3 학생 계정 잠금·학생 RLS 이메일 도메인 확인·함수 search_path 고정
-- 적용: supabase MCP apply_migration (security_5_v3_auth_search_path)
-- v3(입실·퇴실 코드)는 2026-08-01 이후 로그인 0건 — 학생 계정 292개(초기 PIN = 학번)를 잠근다.
--
-- 되돌리기:
--   update auth.users set banned_until = null where email like '%@st.yubongsystem.com';
--   정책은 아래 using 식에서 "and auth.email() like '%@st.yubongsystem.com'" 를 뺀 형태로 재생성.
--   search_path 는 alter function ... reset search_path;

-- 1) v3 학생 계정 잠금(삭제 아님)
update auth.users set banned_until = '2099-12-31 00:00:00+00'
 where email like '%@st.yubongsystem.com';

-- 2) 학생 본인 조회 정책: 학교 학생 도메인 계정만(가입이 열려 있어도 다른 도메인으로 남의 학번 흉내 불가)
drop policy if exists student_read_own_attendance on public.attendance;
create policy student_read_own_attendance on public.attendance for select to authenticated
  using (auth.email() like '%@st.yubongsystem.com'
         and 학번 = split_part(coalesce(auth.email(), ''), '@', 1));
drop policy if exists student_read_own_profile on public.students;
create policy student_read_own_profile on public.students for select to authenticated
  using (auth.email() like '%@st.yubongsystem.com'
         and 학번 = split_part(coalesce(auth.email(), ''), '@', 1));
drop policy if exists student_read_own_correction on public.correction_requests;
create policy student_read_own_correction on public.correction_requests for select to authenticated
  using (auth.email() like '%@st.yubongsystem.com'
         and 학번 = split_part(coalesce(auth.email(), ''), '@', 1));
drop policy if exists student_read_own_daychange on public.day_change_requests;
create policy student_read_own_daychange on public.day_change_requests for select to authenticated
  using (auth.email() like '%@st.yubongsystem.com'
         and 학번 = split_part(coalesce(auth.email(), ''), '@', 1));

-- 3) search_path 가 비어 있던 public 함수 전부 고정
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as f
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f' and p.proconfig is null
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('alter function %s set search_path = public, pg_temp', r.f);
  end loop;
end $$;
