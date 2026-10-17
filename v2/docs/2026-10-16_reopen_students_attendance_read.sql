-- 2026-10-16 사용자 결정: 학생 명단·출석 기록 읽기를 10/14 보안 4b 이전으로 되돌림
-- 적용: supabase MCP apply_migration (v2_reopen_students_attendance_read_20261016)
-- 이유: 명단이 세션을 연 기기에서만 보여 같은 장소 쌍의 다른 칠판에 명단이 안 뜸(roster_load_fail no-key),
--       지난 출석 기록은 관리자 로그인한 탭에서만 보임.
-- 유지: 출석 쓰기 RPC, sessions.session_key 숨김, 요청·좌석·로그 등 나머지 4b 정책.
-- 다시 막기 = 2026-10-14_security_4b_revoke_anon_pii.sql 의 attendance·students 두 묶음.

drop policy if exists anon_read_attendance_scoped on public.attendance;
create policy anon_read_attendance on public.attendance for select to anon using (true);
drop policy if exists anon_read_students_scoped on public.students;
create policy anon_read_students on public.students for select to anon using (true);
