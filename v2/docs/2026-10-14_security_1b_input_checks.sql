-- 2026-10-14 보안 1단계(b): 저장형 XSS 방어용 입력 제약(CHECK)
-- 적용: supabase MCP apply_migration (security_1b_input_checks)
-- 적용 전 기존 행 전부 충족 확인함(위반 0건).
-- 프로그램·장소를 새로 늘리면 아래 cosmos_*_ok 함수 목록도 같이 고칠 것.
--
-- 되돌리기: alter table <표> drop constraint <이름>;  (이름은 아래 *_chk)

create or replace function public.cosmos_program_ok(p text)
returns boolean language sql immutable set search_path = pg_catalog as $$
  select p in ('방과후 독서시간','심야 독서시간','야간 독서시간','일요일 독서시간','토요일 독서시간')
$$;
create or replace function public.cosmos_room_ok(p text)
returns boolean language sql immutable set search_path = pg_catalog as $$
  select p in ('교과1실','리케이온','아우름','해오름')
$$;
create or replace function public.cosmos_name_ok(p text)
returns boolean language sql immutable set search_path = pg_catalog as $$
  select p ~ '^[^<>"&''`]{1,20}$'
$$;
create or replace function public.cosmos_days_ok(p text[])
returns boolean language sql immutable set search_path = pg_catalog as $$
  select coalesce(p, '{}'::text[]) <@ array['월','화','수','목','금','토','일']
$$;

alter table public.students
  add constraint students_input_chk check (
    학번 ~ '^[0-9]{5}$' and cosmos_program_ok(프로그램) and cosmos_room_ok(장소)
    and cosmos_name_ok(이름) and cosmos_days_ok(출석요일)
    and (메모 is null or length(메모) <= 500));

alter table public.correction_requests
  add constraint correction_requests_input_chk check (
    학번 ~ '^[0-9]{5}$' and (이름 is null or cosmos_name_ok(이름))
    and (프로그램 is null or cosmos_program_ok(프로그램))
    and (장소 is null or cosmos_room_ok(장소))
    and (사유 is null or length(사유) <= 200)
    and (상세 is null or length(상세) <= 500)
    and (교사메모 is null or length(교사메모) <= 500));

alter table public.day_change_requests
  add constraint day_change_requests_input_chk check (
    학번 ~ '^[0-9]{5}$' and (이름 is null or cosmos_name_ok(이름))
    and (프로그램 is null or cosmos_program_ok(프로그램))
    and (장소 is null or cosmos_room_ok(장소))
    and cosmos_days_ok(요청요일) and cosmos_days_ok(현재요일)
    and (사유 is null or length(사유) <= 200)
    and (교사메모 is null or length(교사메모) <= 500));

alter table public.sessions
  add constraint sessions_input_chk check (
    cosmos_program_ok(프로그램) and cosmos_room_ok(장소)
    and (교사 is null or (length(교사) <= 30 and 교사 !~ '[<>"&`]')));
