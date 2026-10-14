-- 조회(?mode=check) 사용 중지 (2026-10-14 결정: 안 쓰는 동안 닫아 둠)
-- student_lookup 은 조회 화면만 쓴다(좌석 신청은 student_verify). 실행 권한을 거둔다.
revoke execute on function public.student_lookup(text) from public, anon, authenticated;

-- ── 다시 열 때 ──
-- 1) 아래 한 줄 실행
-- grant execute on function public.student_lookup(text) to anon, authenticated;
-- 2) v2/index.html 의 CHECK_OPEN=true
-- 3) check.html 의 「출석 확인」 카드 주석 해제
