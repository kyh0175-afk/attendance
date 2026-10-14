-- 2026-10-14 보안 4단계(a): 개인정보 조회 범위 제한 준비(함수·RPC만 — 이 파일만으로는 아무것도 막지 않음)
-- 적용: supabase MCP apply_migration (security_4a_scoped_read_rpc)
-- 4b(security_4b_revoke_anon_pii)에서 anon 전체 조회 정책을 이 함수들 기반으로 바꾼다.
--
-- 방식: 프런트가 요청 헤더로 자격을 보낸다(Supabase CORS 는 임의 헤더 허용 확인).
--   x-cosmos-admin : 관리자 토큰(admin_login 이 준 uuid)
--   x-cosmos-skeys : 이 기기가 오늘 만든 세션 키(쉼표 구분, 최대 10개)
-- RLS 정책이 cosmos_req_admin() / cosmos_req_rooms() 로 이 헤더를 확인한다.
--
-- 되돌리기: 4b 되돌리기 후 이 파일의 함수 drop (필수 아님 — 두어도 무해)

create or replace function public.cosmos_hdr(p_name text)
returns text language plpgsql stable set search_path = pg_catalog as $$
begin
  return nullif(current_setting('request.headers', true), '')::json ->> p_name;
exception when others then
  return null;
end $$;

create or replace function public.cosmos_req_admin()
returns boolean language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v text := cosmos_hdr('x-cosmos-admin');
begin
  if v is null or v !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;
  return exists (select 1 from admin_sessions where token = v::uuid and expires_at > now());
end $$;

-- 헤더의 세션 키가 가리키는 오늘 세션들의 장소(장소 쌍 포함)
create or replace function public.cosmos_req_rooms()
returns text[] language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v    text := cosmos_hdr('x-cosmos-skeys');
  ks   uuid[];
  r    text[];
begin
  if v is null or v = '' then return '{}'::text[]; end if;
  select coalesce(array_agg(x::uuid), '{}') into ks
    from (select trim(x) x from unnest(string_to_array(v, ',')) x limit 10) t
   where x ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  if array_length(ks, 1) is null then return '{}'::text[]; end if;
  select coalesce(array_agg(distinct g), '{}') into r
    from sessions s, unnest(cosmos_room_group(s.장소)) g
   where s.session_key = any (ks)
     and s.날짜 = (now() at time zone 'Asia/Seoul')::date;
  return r;
end $$;

create or replace function public.cosmos_today()
returns date language sql stable set search_path = pg_catalog as $$
  select (now() at time zone 'Asia/Seoul')::date
$$;

-- ── 학생 본인 조회(?mode=check, 좌석 신청 로그인): 이름 없이 그 학번 것만 ──
create or replace function public.student_lookup(p_hakbun text)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if p_hakbun is null or p_hakbun !~ '^[0-9]{5}$' then
    return jsonb_build_object('found', false);
  end if;
  if not exists (select 1 from students where 학번 = p_hakbun and 활성) then
    return jsonb_build_object('found', false);
  end if;
  return jsonb_build_object(
    'found', true,
    'programs', (select coalesce(jsonb_agg(jsonb_build_object('program', 프로그램, 'location', 장소,
                    'days', coalesce(출석요일, '{}'::text[])) order by 프로그램), '[]')
                   from students where 학번 = p_hakbun and 활성),
    'records', (select coalesce(jsonb_agg(jsonb_build_object('date', 날짜, 'program', 프로그램, 'location', 장소,
                    'late', 사후여부, 'status', 상태) order by 날짜 desc), '[]')
                  from attendance where 학번 = p_hakbun),
    'requests', (select coalesce(jsonb_agg(jsonb_build_object('id', id, '대상날짜', 대상날짜, '프로그램', 프로그램,
                    '장소', 장소, '사유', 사유, '처리상태', 처리상태, '교사메모', 교사메모, '요청일시', 요청일시)
                    order by 요청일시 desc), '[]')
                   from correction_requests where 학번 = p_hakbun),
    'dayRequests', (select coalesce(jsonb_agg(jsonb_build_object('id', id, '프로그램', 프로그램, '장소', 장소,
                    '현재요일', 현재요일, '요청요일', 요청요일, '사유', 사유, '처리상태', 처리상태,
                    '교사메모', 교사메모, '요청일시', 요청일시) order by 요청일시 desc), '[]')
                   from day_change_requests where 학번 = p_hakbun)
  );
end $$;

-- 요청 테이블: 이름은 서버가 명단에서 채운다(학생 화면은 이름을 모름)
create or replace function public.trg_request_fill_name()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if NEW.이름 is null or NEW.이름 = '' then
    select 이름 into NEW.이름 from students where 학번 = NEW.학번 order by 활성 desc limit 1;
  end if;
  if current_user in ('anon', 'authenticated') then
    NEW.처리상태 := '대기';
    NEW.교사메모 := null;
    NEW.처리일시 := null;
  end if;
  return NEW;
end $$;
drop trigger if exists correction_requests_fill_name on public.correction_requests;
create trigger correction_requests_fill_name before insert on public.correction_requests
  for each row execute function public.trg_request_fill_name();
drop trigger if exists day_change_requests_fill_name on public.day_change_requests;
create trigger day_change_requests_fill_name before insert on public.day_change_requests
  for each row execute function public.trg_request_fill_name();

-- ── 좌석 신청(학생): 남의 이름·학번 없이 점유 좌석만 ──
create or replace function public.seat_request_board(p_period_id bigint, p_hakbun text)
returns table(장소 text, 좌석번호 integer, mine boolean)
language sql stable security definer set search_path = public, pg_temp as $$
  select r.장소, r.좌석번호, (r.학번 = p_hakbun) from seat_requests r where r.period_id = p_period_id
$$;
create or replace function public.seat_month_occupied(p_month text)
returns table(장소 text, 좌석번호 integer, period_id bigint, 허용학년 integer[])
language sql stable security definer set search_path = public, pg_temp as $$
  select r.장소, r.좌석번호, r.period_id, p.허용학년
    from seat_requests r join seat_periods p on r.period_id = p.id
   where p.좌석배치월 = p_month
$$;

-- 좌석 신청: 이름은 서버가 채우고, 이미 신청한 학번은 처음 신청한 기기(edit_key)에서만 바꿀 수 있다
alter table public.seat_requests add column if not exists edit_key uuid;
-- edit_key 는 4b 이후 관리자(헤더)만 읽는다

create or replace function public.submit_seat_request_v2(
  p_period_id bigint, p_hakbun text, p_room text, p_seat integer, p_edit_key uuid default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  period_row    seat_periods%rowtype;
  v_name        text;
  v_grade       int;
  v_existing    seat_requests%rowtype;
  v_key         uuid;
  v_id          bigint;
begin
  if p_hakbun is null or p_hakbun !~ '^[0-9]{5}$' then
    raise exception '학번 형식이 올바르지 않아요';
  end if;
  if p_room not in ('해오름', '리케이온') then
    raise exception '유효하지 않은 장소입니다: %', p_room;
  end if;
  select * into period_row from seat_periods where id = p_period_id;
  if not found then raise exception '존재하지 않는 신청 기간입니다'; end if;
  if period_row.상태 <> 'open' then
    raise exception '현재 신청을 받지 않는 기간입니다 (상태: %)', period_row.상태;
  end if;
  if now() < period_row.신청시작 then raise exception '아직 신청 시작 시각이 되지 않았습니다'; end if;
  if now() > period_row.신청마감 then raise exception '신청 마감 시각이 지났습니다'; end if;
  v_grade := (left(p_hakbun, 1))::int;
  if not (v_grade = any (period_row.허용학년)) then
    raise exception '이 신청 기간은 % 학년만 신청할 수 있습니다', array_to_string(period_row.허용학년, ', ');
  end if;
  select 이름 into v_name from students where 학번 = p_hakbun and 활성 order by 프로그램 limit 1;
  if v_name is null then raise exception '등록되지 않은 학번이에요'; end if;

  if period_row.좌석배치월 is not null and exists (
    select 1 from seat_requests r join seat_periods p on r.period_id = p.id
     where p.좌석배치월 = period_row.좌석배치월 and r.장소 = p_room and r.좌석번호 = p_seat
       and r.학번 <> p_hakbun) then
    raise exception '이미 다른 학생이 신청한 자리입니다';
  end if;

  select * into v_existing from seat_requests where period_id = p_period_id and 학번 = p_hakbun;
  if found then
    if v_existing.edit_key is not null and (p_edit_key is null or p_edit_key <> v_existing.edit_key) then
      raise exception '이미 신청한 학번이에요. 자리를 바꾸려면 처음 신청한 기기에서 하거나 선생님께 말해 주세요.';
    end if;
    v_key := coalesce(v_existing.edit_key, gen_random_uuid());
    update seat_requests set 장소 = p_room, 좌석번호 = p_seat, 신청일시 = now(), 이름 = v_name, edit_key = v_key
     where id = v_existing.id returning id into v_id;
  else
    v_key := gen_random_uuid();
    insert into seat_requests (period_id, 학번, 이름, 장소, 좌석번호, 신청일시, edit_key)
    values (p_period_id, p_hakbun, v_name, p_room, p_seat, now(), v_key)
    returning id into v_id;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id, 'edit_key', v_key);
end $$;

-- 이름이 나가던 관리자용 함수: 관리자 헤더 없으면 빈 결과
create or replace function public.get_cosmos_conflicts(p_month text)
returns table(프로그램 text, 장소 text, 좌석번호 integer, 요일 text, 학번들 text[], 이름들 text[])
language plpgsql stable security definer set search_path = public, pg_temp as $function$
begin
  if not cosmos_req_admin() then return; end if;
  return query
  with expanded as (
    select s.프로그램 as pg, s.장소 as rm, s.좌석번호 as sn, unnest(s.요일) as dy, s.학번 as hb, m.이름 as nm
      from cosmos_schedule s join cosmos_members m on s.학번 = m.학번
     where s.좌석배치월 = p_month and s.좌석번호 is not null)
  select e.pg, e.rm, e.sn, e.dy, array_agg(e.hb order by e.hb), array_agg(e.nm order by e.hb)
    from expanded e
   group by e.pg, e.rm, e.sn, e.dy
  having count(*) > 1;
end $function$;

create or replace function public.check_cosmos_conflict(
  "p_좌석배치월" text, "p_프로그램" text, "p_장소" text, "p_좌석번호" integer, "p_요일" text[],
  p_exclude_id bigint default null)
returns table(요일 text, 학번 text, 이름 text)
language plpgsql stable security definer set search_path = public, pg_temp as $function$
begin
  if not cosmos_req_admin() then return; end if;
  return query
  select distinct d, s.학번, m.이름
    from cosmos_schedule s
    join cosmos_members m on s.학번 = m.학번
    cross join lateral unnest(s.요일) d
   where s.좌석배치월 = "p_좌석배치월" and s.프로그램 = "p_프로그램" and s.장소 = "p_장소"
     and s.좌석번호 = "p_좌석번호" and "p_좌석번호" is not null and d = any ("p_요일")
     and (p_exclude_id is null or s.id <> p_exclude_id)
   order by 1, 2;
end $function$;

create or replace function public.get_month_occupied_seats(p_month text)
returns table(장소 text, 좌석번호 integer, 학번 text, 이름 text, period_id bigint, 허용학년 integer[])
language plpgsql stable security definer set search_path = public, pg_temp as $function$
begin
  if not cosmos_req_admin() then return; end if;
  return query
  select r.장소, r.좌석번호, r.학번, r.이름, r.period_id, p.허용학년
    from seat_requests r join seat_periods p on r.period_id = p.id
   where p.좌석배치월 = p_month;
end $function$;

grant execute on function public.student_lookup(text) to anon, authenticated;
grant execute on function public.seat_request_board(bigint, text) to anon, authenticated;
grant execute on function public.seat_month_occupied(text) to anon, authenticated;
grant execute on function public.submit_seat_request_v2(bigint, text, text, integer, uuid) to anon, authenticated;
grant execute on function public.cosmos_req_admin() to anon, authenticated;
grant execute on function public.cosmos_req_rooms() to anon, authenticated;
grant execute on function public.cosmos_today() to anon, authenticated;
revoke execute on function public.trg_request_fill_name() from public, anon, authenticated;

-- (4a2) 좌석 신청 본인 확인: 학번+이름 일치 여부만 돌려준다
create or replace function public.student_verify(p_hakbun text, p_name text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select p_hakbun ~ '^[0-9]{5}$' and exists (
    select 1 from students
     where 학번 = p_hakbun and 활성
       and regexp_replace(이름, '\s', '', 'g') = regexp_replace(coalesce(p_name, ''), '\s', '', 'g'))
$$;
grant execute on function public.student_verify(text, text) to anon, authenticated;
