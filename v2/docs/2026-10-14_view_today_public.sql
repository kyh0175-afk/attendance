-- 2026-10-14 저녁: 4c(오늘 출석 기록 = 세션 키 기기·관리자만) 되돌림 — 사용자 결정
-- 이유: 감독 교사가 칠판이 아닌 기기에서 「출석 기록 조회」를 눌러도 비밀번호 없이 오늘 기록을 보게.
-- 적용: 사용자가 SQL Editor 에서 직접 실행(2026-10-14), 정책 반영 확인.
-- 범위: anon 은 오늘(KST) 출석 기록만. 지난 날짜·학생 명단(students)은 그대로 막힘
--       → 칠판이 아닌 기기의 View 는 출석자만 보이고 미출석·출석률은 칠판(세션 키)·관리자에서.
--
-- 다시 막기 = 2026-10-14_security_4c_view_needs_key.sql 본문 + index.html enterAdminScreen 의 키 검사 복구.

drop policy if exists anon_read_attendance_scoped on public.attendance;
create policy anon_read_attendance_scoped on public.attendance for select to anon
  using ((select cosmos_req_admin()) or 날짜 = (select cosmos_today()));
