-- 요청 표 insert 는 언제나 '대기'로 (2026-10-16)
-- 문제: trg_request_fill_name 이 SECURITY DEFINER 라 함수 안의 current_user 가 늘 소유자 →
--       "anon·authenticated 면 대기로 강제" 조건이 한 번도 참이 되지 않아, 로그인 없이
--       day_change_requests·correction_requests 에 처리상태 '승인' 행을 직접 넣을 수 있었다(10/16 되돌림 시험으로 확인).
--       분석 요일 이력(index.html ensureDayChangeHist)이 승인 행을 읽으므로 임의 학번의 과거 출석률 판정이 바뀔 수 있었다.
-- 조치: 누가 넣든 insert 는 대기·교사메모 null·처리일시 null. 승인·거절은 관리자 RPC 의 update 로만.
--       (insert 로 승인 행을 만드는 함수 없음 — 10/16 pg_proc 검색 0건. 요일 조사 승인은 insert 뒤 update.)
-- 학생 요청 화면 사용법은 그대로(원래 대기로 넣던 것).

create or replace function public.trg_request_fill_name()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
begin
  if NEW.이름 is null or NEW.이름 = '' then
    select 이름 into NEW.이름 from students where 학번 = NEW.학번 order by 활성 desc limit 1;
  end if;
  NEW.처리상태 := '대기';
  NEW.교사메모 := null;
  NEW.처리일시 := null;
  return NEW;
end $function$;

-- ── 되돌리기(10/16 이전 정의) ───────────────────────────────────
-- create or replace function public.trg_request_fill_name() returns trigger language plpgsql security definer
--  set search_path to 'public', 'pg_temp' as $f$
-- begin
--   if NEW.이름 is null or NEW.이름 = '' then
--     select 이름 into NEW.이름 from students where 학번 = NEW.학번 order by 활성 desc limit 1;
--   end if;
--   if current_user in ('anon', 'authenticated') then
--     NEW.처리상태 := '대기'; NEW.교사메모 := null; NEW.처리일시 := null;
--   end if;
--   return NEW;
-- end $f$;
