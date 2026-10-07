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

-- ═══════════════════════════════════════════════════════════════
--  추가(같은 날): 감독표 자동 동기화
--   migration v2_supervisor_slots_20261007 + v2_sync_supervisor_respect_manual_20261007(리뷰 #5 반영본)
--  실행: .github/workflows/supervisor-sync.yml → .github/scripts/sync_supervisors.py
--  Secrets: SUPERVISOR_XLSX_URL(공유 링크), SUPERVISOR_SYNC_TOKEN(원문) — DB에는 sha256 해시만
-- ═══════════════════════════════════════════════════════════════
create table if not exists public.supervisor_slots (
  날짜       date not null,
  프로그램   text not null check (프로그램 in ('방과후 독서시간','야간 독서시간','심야 독서시간','토요일 독서시간','일요일 독서시간')),
  장소그룹   text not null check (장소그룹 in ('아우름+교과1실','해오름+리케이온','리케이온')),
  시간대     text not null default '' check (시간대 in ('','오전','오후')),
  교사명     text not null check (char_length(교사명) between 1 and 20 and 교사명 !~ '[<>"`\\]'),
  수정일시   timestamptz not null default now(),
  primary key (날짜, 프로그램, 장소그룹, 시간대)
);
alter table public.supervisor_slots enable row level security;
create policy supervisor_slots_read on public.supervisor_slots for select to anon, authenticated using (true);
revoke insert, update, delete, truncate on public.supervisor_slots from anon, authenticated;
grant select on public.supervisor_slots to anon, authenticated;

create table if not exists public.sync_tokens (
  name        text primary key,
  token_hash  text not null,
  만든일시    timestamptz not null default now()
);
alter table public.sync_tokens enable row level security;   -- 정책 없음 = anon·authenticated 읽기 불가
revoke all on public.sync_tokens from anon, authenticated;
-- 토큰 교체: 새 원문을 만들어 GitHub Secret SUPERVISOR_SYNC_TOKEN을 바꾸고, 아래 해시만 갱신
--   insert into public.sync_tokens(name, token_hash) values ('supervisors', '<sha256 hex>')
--   on conflict (name) do update set token_hash = excluded.token_hash, 만든일시 = now();

-- p_rows: [{"날짜":"2026-10-01","프로그램":"심야 독서시간","장소그룹":"리케이온","시간대":"","교사명":"이름"|null}, ...]
-- 교사명 null = 그 칸 지움. 심야는 supervisors에도 기록하되, 메모가 '감독표 자동'인 행만 덮어쓰거나 지운다(직접 넣은 대체 감독 보호).
create or replace function public.sync_supervisor_slots(p_token text, p_rows jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  r jsonb; n_up int := 0; n_del int := 0;
begin
  if p_token is null or not exists (
    select 1 from sync_tokens where name = 'supervisors'
      and token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')) then
    raise exception '동기화 토큰이 올바르지 않습니다' using errcode = 'insufficient_privilege';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 2000 then
    raise exception '형식 오류' using errcode = 'check_violation';
  end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    if r->>'교사명' is null or btrim(r->>'교사명') = '' then
      delete from supervisor_slots
       where 날짜 = (r->>'날짜')::date and 프로그램 = r->>'프로그램'
         and 장소그룹 = r->>'장소그룹' and 시간대 = coalesce(r->>'시간대', '');
      if r->>'프로그램' = '심야 독서시간' then
        delete from supervisors where 날짜 = (r->>'날짜')::date and 메모 = '감독표 자동';
      end if;
      n_del := n_del + 1;
    else
      insert into supervisor_slots(날짜, 프로그램, 장소그룹, 시간대, 교사명, 수정일시)
      values ((r->>'날짜')::date, r->>'프로그램', r->>'장소그룹', coalesce(r->>'시간대', ''), btrim(r->>'교사명'), now())
      on conflict (날짜, 프로그램, 장소그룹, 시간대)
      do update set 교사명 = excluded.교사명, 수정일시 = now()
      where supervisor_slots.교사명 is distinct from excluded.교사명;
      if r->>'프로그램' = '심야 독서시간' then
        insert into supervisors(날짜, 교사명, 메모) values ((r->>'날짜')::date, btrim(r->>'교사명'), '감독표 자동')
        on conflict (날짜) do update set 교사명 = excluded.교사명, 메모 = '감독표 자동'
        where supervisors.메모 = '감독표 자동';
      end if;
      n_up := n_up + 1;
    end if;
  end loop;
  return jsonb_build_object('upserted', n_up, 'cleared', n_del);
end$function$;
revoke all on function public.sync_supervisor_slots(text, jsonb) from public;
grant execute on function public.sync_supervisor_slots(text, jsonb) to anon, authenticated;
