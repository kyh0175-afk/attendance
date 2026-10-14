-- 2026-10-14 보안 4단계(b): anon 전체 조회·쓰기 정책을 헤더 자격 기반으로 교체
-- 적용: supabase MCP apply_migration (security_4b_revoke_anon_pii)
-- 전제: 4a + 프런트(631add5, 요청 헤더 x-cosmos-admin / x-cosmos-skeys) 배포.
--
-- 결과(anon, 자격 헤더 없음):
--   attendance        : 오늘(KST) 기록만 (View 화면·칠판 실시간 목록용 — 감독 교사가 다른 기기로 봄)
--   students          : 없음 (관리자 헤더 = 전체, 세션 키 헤더 = 그 방(장소 쌍) 명단)
--   teacher_logs      : 쓰기만, 읽기는 관리자
--   correction/day_change_requests : 등록만(서버가 대기·이름 채움), 읽기·수정은 관리자
--   cosmos_members/cosmos_schedule, seat_requests/seat_assignments : 관리자만
--   seats             : 관리자 또는 그 방 세션 키
--   supervisors       : 읽기 유지(교사 이름), 쓰기 관리자
--   seat_room_enabled : 읽기 유지, 수정 관리자
--
-- 되돌리기(옛 정책 복구):
--   drop policy anon_read_attendance_scoped on attendance;  create policy anon_read_attendance on attendance for select to anon using (true);
--   drop policy anon_read_students_scoped on students;      create policy anon_read_students on students for select to anon using (true);
--   drop policy teacher_logs_admin_select on teacher_logs;  create policy teacher_logs_anon_select on teacher_logs for select to anon using (true);
--   drop policy correction_requests_anon_insert on correction_requests; drop policy correction_requests_admin_all on correction_requests;
--     create policy anon_all_correction_requests on correction_requests for all to anon using (true) with check (true);
--   (day_change_requests 같은 방식, anon_all_day_change_requests)
--   drop policy cosmos_members_admin on cosmos_members; create policy cosmos_members_all on cosmos_members for all to anon, authenticated, service_role using (true) with check (true);
--   drop policy cosmos_schedule_admin on cosmos_schedule; create policy cosmos_schedule_all on cosmos_schedule for all to anon, authenticated, service_role using (true) with check (true);
--   drop policy seat_requests_admin_read on seat_requests; create policy seat_requests_read on seat_requests for select using (true);
--   drop policy seat_assignments_admin_read on seat_assignments; create policy seat_assignments_read on seat_assignments for select using (true);
--   drop policy seats_scoped on seats; create policy anon_all_seats on seats for all to anon using (true) with check (true);
--   drop policy supervisors_read on supervisors; drop policy supervisors_admin_write on supervisors;
--     create policy anon_all_supervisors on supervisors for all to anon using (true) with check (true);
--   drop policy seat_room_enabled_admin_update on seat_room_enabled; create policy seat_room_enabled_update on seat_room_enabled for update using (true) with check (true);

-- attendance
drop policy if exists anon_read_attendance on public.attendance;
create policy anon_read_attendance_scoped on public.attendance for select to anon
  using ((select cosmos_req_admin()) or 날짜 = (select cosmos_today()));

-- students
drop policy if exists anon_read_students on public.students;
create policy anon_read_students_scoped on public.students for select to anon
  using ((select cosmos_req_admin()) or (select cosmos_req_rooms()) @> array[장소]);

-- teacher_logs
drop policy if exists teacher_logs_anon_select on public.teacher_logs;
create policy teacher_logs_admin_select on public.teacher_logs for select to anon
  using ((select cosmos_req_admin()));

-- 요청 2종
drop policy if exists anon_all_correction_requests on public.correction_requests;
create policy correction_requests_anon_insert on public.correction_requests for insert to anon
  with check (true);
create policy correction_requests_admin_all on public.correction_requests for all to anon
  using ((select cosmos_req_admin())) with check ((select cosmos_req_admin()));
drop policy if exists anon_all_day_change_requests on public.day_change_requests;
create policy day_change_requests_anon_insert on public.day_change_requests for insert to anon
  with check (true);
create policy day_change_requests_admin_all on public.day_change_requests for all to anon
  using ((select cosmos_req_admin())) with check ((select cosmos_req_admin()));

-- 코스모스 명단·배치
drop policy if exists cosmos_members_all on public.cosmos_members;
create policy cosmos_members_admin on public.cosmos_members for all to anon, authenticated
  using ((select cosmos_req_admin())) with check ((select cosmos_req_admin()));
drop policy if exists cosmos_schedule_all on public.cosmos_schedule;
create policy cosmos_schedule_admin on public.cosmos_schedule for all to anon, authenticated
  using ((select cosmos_req_admin())) with check ((select cosmos_req_admin()));

-- 좌석 신청·확정
drop policy if exists seat_requests_read on public.seat_requests;
create policy seat_requests_admin_read on public.seat_requests for select to anon, authenticated
  using ((select cosmos_req_admin()));
drop policy if exists seat_assignments_read on public.seat_assignments;
create policy seat_assignments_admin_read on public.seat_assignments for select to anon, authenticated
  using ((select cosmos_req_admin()));

-- seats
drop policy if exists anon_all_seats on public.seats;
create policy seats_scoped on public.seats for all to anon
  using ((select cosmos_req_admin()) or (select cosmos_req_rooms()) @> array[장소])
  with check ((select cosmos_req_admin()) or (select cosmos_req_rooms()) @> array[장소]);

-- supervisors
drop policy if exists anon_all_supervisors on public.supervisors;
create policy supervisors_read on public.supervisors for select to anon using (true);
create policy supervisors_admin_write on public.supervisors for all to anon
  using ((select cosmos_req_admin())) with check ((select cosmos_req_admin()));

-- seat_room_enabled
drop policy if exists seat_room_enabled_update on public.seat_room_enabled;
create policy seat_room_enabled_admin_update on public.seat_room_enabled for update to anon, authenticated
  using ((select cosmos_req_admin())) with check ((select cosmos_req_admin()));

-- 옛 좌석 신청 RPC(이름·덮어쓰기)와 이름 나가는 함수는 anon 실행 회수
revoke execute on function public.submit_seat_request(bigint, text, text, text, integer) from public, anon, authenticated;
