-- ═══════════════════════════════════════════════════════════════
--  v2 보안 보강 (2026-10-07) — 사용법은 바꾸지 않는 서버 쪽 보강
--  배경: v2 리뷰 S3·S4(저장형 XSS 경로), S18(출석 취소 RPC), 요청 테이블 anon 삭제
--  선행: 화면 커밋 9dde2fc(수동 출석에 메모 '수동') 배포 후 적용할 것
--  사전 점검(2026-10-07): 네 테이블 모두 학번 형식 위반 0건, 이름 특수문자 0건
-- ═══════════════════════════════════════════════════════════════

-- 1) 학번은 5자리 숫자만 — anon INSERT(요청·자가등록)로 HTML/스크립트가 들어오는 경로 차단
alter table public.students            add constraint students_학번_format            check (학번 ~ '^\d{5}$');
alter table public.attendance          add constraint attendance_학번_format          check (학번 ~ '^\d{5}$');
alter table public.correction_requests add constraint correction_requests_학번_format check (학번 ~ '^\d{5}$');
alter table public.day_change_requests add constraint day_change_requests_학번_format check (학번 ~ '^\d{5}$');
alter table public.seat_requests       add constraint seat_requests_학번_format       check (학번 ~ '^\d{5}$');

-- 2) 이름은 20자 이하, < > " ` \ 금지 (현재 최대 8자)
alter table public.students            add constraint students_이름_safe            check (이름 is null or (char_length(이름) <= 20 and 이름 !~ '[<>"`\\]'));
alter table public.attendance          add constraint attendance_이름_safe          check (이름 is null or (char_length(이름) <= 20 and 이름 !~ '[<>"`\\]'));
alter table public.correction_requests add constraint correction_requests_이름_safe check (이름 is null or (char_length(이름) <= 20 and 이름 !~ '[<>"`\\]'));
alter table public.day_change_requests add constraint day_change_requests_이름_safe check (이름 is null or (char_length(이름) <= 20 and 이름 !~ '[<>"`\\]'));

-- 3) 출석 취소는 교사 수동 출석(메모 '수동')만, 15분 안 — id만 알면 학생 본인 QR 출석을 지울 수 있던 문제
create or replace function public.undo_recent_attendance(p_id bigint)
 returns boolean
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare n int;
begin
  delete from attendance
   where id = p_id
     and 사후여부 = false
     and 메모 = '수동'
     and 생성일시 > now() - interval '15 minutes';
  get diagnostics n = row_count;
  return n > 0;
end$function$;

-- 4) 요청 테이블: 화면이 쓰지 않는 anon DELETE 회수(누구나 요청을 지울 수 있었다)
revoke delete on public.correction_requests, public.day_change_requests from anon;

-- 5) TRUNCATE는 앱이 쓰지 않는다 — anon·authenticated에서 회수(방어적)
revoke truncate on all tables in schema public from anon, authenticated;

-- 되돌리기(필요 시):
--   alter table … drop constraint <이름>;  (위 9개)
--   undo_recent_attendance 에서 "and 메모 = '수동'" 줄 제거
--   grant delete on public.correction_requests, public.day_change_requests to anon;

-- ═══════════════════════════════════════════════════════════════
--  추가(같은 날, migration v2_admin_set_setting_20261007): 관리자 화면에서 학기 시작일 저장
-- ═══════════════════════════════════════════════════════════════
create or replace function public.admin_set_setting(p_token uuid, p_key text, p_value text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
begin
  perform assert_admin(p_token);
  if p_key not in ('semester_start') then
    raise exception '바꿀 수 없는 설정입니다: %', p_key using errcode = 'check_violation';
  end if;
  if p_key = 'semester_start' and p_value !~ '^\d{4}-\d{2}-\d{2}$' then
    raise exception '날짜 형식(YYYY-MM-DD)이 아닙니다' using errcode = 'check_violation';
  end if;
  insert into system_settings(key, value, 수정일시) values (p_key, p_value, now())
  on conflict (key) do update set value = excluded.value, 수정일시 = now();
end$function$;
revoke all on function public.admin_set_setting(uuid, text, text) from public;
grant execute on function public.admin_set_setting(uuid, text, text) to anon, authenticated;
