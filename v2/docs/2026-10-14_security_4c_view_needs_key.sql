-- 2026-10-14 보안 4단계(c): 오늘 출석 기록도 세션 키(그 칠판 기기) 또는 관리자만
-- 적용: supabase MCP apply_migration (security_4c_view_needs_key)
-- 사용자 결정: QR 세션은 고정 장소의 고정 기기에서만 연다 → View·사후 출석은 그 기기(오늘 키) 또는 관리자.
-- Realtime 은 헤더가 없어 이 정책으로 이벤트가 오지 않는다 — 칠판 화면은 3초 폴링으로 갱신(기존 백업 경로).
--
-- 되돌리기(오늘 기록 공개로):
--   drop policy anon_read_attendance_scoped on public.attendance;
--   create policy anon_read_attendance_scoped on public.attendance for select to anon
--     using ((select cosmos_req_admin()) or 날짜 = (select cosmos_today()));

drop policy if exists anon_read_attendance_scoped on public.attendance;
create policy anon_read_attendance_scoped on public.attendance for select to anon
  using ((select cosmos_req_admin())
         or (날짜 = (select cosmos_today()) and cardinality((select cosmos_req_rooms())) > 0));
