-- 2026-10-14 보안 2단계(a): 출석 쓰기를 RPC로 (기존 경로와 병행 — 이 파일만으로는 아무것도 막지 않음)
-- 적용: supabase MCP apply_migration (security_2a_checkin_rpc)
-- 2b(security_2b_lock_attendance_insert)에서 anon 직접 INSERT 를 막는다.
--
-- 되돌리기: drop function student_check_in(text,text,text,text);
--           drop function teacher_check_in(text,text,uuid,uuid,boolean,text);
--           drop function undo_recent_attendance(bigint,uuid,uuid);
--           alter table sessions drop column session_key;  (프런트가 쓰고 있으면 먼저 프런트 되돌림)

-- 세션 비밀키: 세션을 만든 교사 기기만 안다(프런트가 만들 때 직접 생성해 넣고 localStorage 에 보관)
alter table public.sessions add column if not exists session_key uuid default gen_random_uuid();

-- 장소 쌍(통합 방) — 프런트 getRoomGroup 과 같음
create or replace function public.cosmos_room_group(p_room text)
returns text[] language sql immutable set search_path = pg_catalog as $$
  select case
    when p_room in ('아우름','교과1실') then array['아우름','교과1실']
    when p_room in ('리케이온','해오름') then array['리케이온','해오름']
    else array[p_room] end
$$;

-- 키가 가리키는 세션과 같은 날짜·같은 장소 쌍이면 통과
create or replace function public.cosmos_key_covers(p_key uuid, p_date date, p_room text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select p_key is not null and exists (
    select 1 from sessions k
     where k.session_key = p_key
       and k.날짜 = p_date
       and k.장소 = any (cosmos_room_group(p_room)))
$$;

create or replace function public.cosmos_admin_token_ok(p_token uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select p_token is not null and exists (select 1 from admin_sessions where token = p_token and expires_at > now())
$$;

-- ── 학생 QR 출석 ───────────────────────────────────────────
-- 반환: {ok, already, id, name, code, msg}
--   code: ok | already | not_registered | no_session | closed | bad_input
create or replace function public.student_check_in(
  p_session_id text, p_hakbun text, p_room text default null, p_time text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  s     sessions;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_now_t time := (now() at time zone 'Asia/Seoul')::time(0);
  v_room text;
  v_name text;
  v_t    time;
  v_id   bigint;
begin
  if p_hakbun is null or p_hakbun !~ '^[0-9]{5}$' or p_session_id is null or length(p_session_id) > 40 then
    return jsonb_build_object('ok', false, 'code', 'bad_input', 'msg', '학번 형식이 올바르지 않아요.');
  end if;

  select * into s from sessions
   where 세션id = p_session_id
   order by (장소 = p_room) desc nulls last, id
   limit 1;
  if s.id is null then
    return jsonb_build_object('ok', false, 'code', 'no_session', 'msg', '세션을 찾을 수 없어요. 새 QR을 받아주세요.');
  end if;
  if s.활성 is not true or s.종료시각 is not null
     or (s.만료시각 is not null and s.만료시각 < now()) or s.날짜 <> v_today then
    return jsonb_build_object('ok', false, 'code', 'closed', 'msg', '이 세션은 이미 마감됐어요. 선생님께 새 QR을 요청해주세요.');
  end if;

  v_room := case when p_room = any (cosmos_room_group(s.장소)) then p_room else s.장소 end;

  select st.이름 into v_name from students st
   where st.학번 = p_hakbun
   order by (st.프로그램 = s.프로그램 and st.장소 = v_room) desc,
            (st.프로그램 = s.프로그램 and st.장소 = any (cosmos_room_group(s.장소))) desc,
            (st.장소 = v_room) desc, st.활성 desc
   limit 1;
  if v_name is null then
    return jsonb_build_object('ok', false, 'code', 'not_registered', 'msg', '명단에 없는 학번이에요.');
  end if;

  -- 원래시각: 기기 시각(약신호 대기분)을 받되, 세션 시작~지금 사이일 때만
  v_t := v_now_t;
  if p_time ~ '^[0-2][0-9]:[0-5][0-9](:[0-5][0-9])?$' then
    begin
      if p_time::time <= v_now_t and p_time::time >= (s.시작시각 at time zone 'Asia/Seoul')::time(0) then
        v_t := p_time::time(0);
      end if;
    exception when others then v_t := v_now_t;
    end;
  end if;

  insert into attendance(세션id, 학번, 이름, 날짜, 원래시각, 처리시각, 사후여부, 프로그램, 장소, 교사, 상태, 메모)
  values (s.세션id, p_hakbun, v_name, s.날짜, v_t, null, false, s.프로그램, v_room, nullif(s.교사, ''), '출석', null)
  on conflict (학번, 세션id) do nothing
  returning id into v_id;

  if v_id is null then
    return jsonb_build_object('ok', true, 'already', true, 'code', 'already', 'name', v_name);
  end if;
  return jsonb_build_object('ok', true, 'already', false, 'code', 'ok', 'id', v_id, 'name', v_name);
end
$function$;

-- ── 교사 수동 출석 / 사후 출석 ─────────────────────────────
-- 권한: 같은 날·같은 장소 쌍 세션의 session_key(그 교사 기기) 또는 관리자 토큰
create or replace function public.teacher_check_in(
  p_session_id text, p_hakbun text, p_key uuid default null, p_token uuid default null,
  p_late boolean default false, p_room text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  s      sessions;
  v_room text;
  v_name text;
  v_id   bigint;
  v_admin boolean := cosmos_admin_token_ok(p_token);
begin
  if p_hakbun is null or p_hakbun !~ '^[0-9]{5}$' then
    return jsonb_build_object('ok', false, 'code', 'bad_input', 'msg', '학번 형식이 올바르지 않아요.');
  end if;
  select * into s from sessions
   where 세션id = p_session_id
   order by (장소 = p_room) desc nulls last, id
   limit 1;
  if s.id is null then
    return jsonb_build_object('ok', false, 'code', 'no_session', 'msg', '세션을 찾을 수 없어요.');
  end if;
  if not v_admin and not cosmos_key_covers(p_key, s.날짜, s.장소) then
    return jsonb_build_object('ok', false, 'code', 'forbidden',
      'msg', '이 기기에서는 처리할 수 없어요. 이 방의 QR을 연 기기나 관리자 화면에서 해 주세요.');
  end if;

  v_room := case when p_room = any (cosmos_room_group(s.장소)) then p_room else s.장소 end;
  select st.이름 into v_name from students st
   where st.학번 = p_hakbun
   order by (st.프로그램 = s.프로그램 and st.장소 = v_room) desc,
            (st.프로그램 = s.프로그램) desc, (st.장소 = v_room) desc, st.활성 desc
   limit 1;
  if v_name is null then
    return jsonb_build_object('ok', false, 'code', 'not_registered', 'msg', '명단에 없는 학번이에요');
  end if;

  if coalesce(p_late, false) then
    insert into attendance(세션id, 학번, 이름, 날짜, 원래시각, 처리시각, 사후여부, 프로그램, 장소, 교사, 상태, 메모)
    values (s.세션id, p_hakbun, v_name, s.날짜, null, now(), true, s.프로그램, v_room, nullif(s.교사, ''), '출석', null)
    on conflict (학번, 세션id) do nothing
    returning id into v_id;
  else
    insert into attendance(세션id, 학번, 이름, 날짜, 원래시각, 처리시각, 사후여부, 프로그램, 장소, 교사, 상태, 메모)
    values (s.세션id, p_hakbun, v_name, s.날짜, (now() at time zone 'Asia/Seoul')::time(0), null, false,
            s.프로그램, v_room, nullif(s.교사, ''), '출석', '수동')
    on conflict (학번, 세션id) do nothing
    returning id into v_id;
  end if;

  if v_id is null then
    return jsonb_build_object('ok', true, 'already', true, 'code', 'already', 'name', v_name);
  end if;
  return jsonb_build_object('ok', true, 'already', false, 'code', 'ok', 'id', v_id, 'name', v_name);
end
$function$;

-- ── 수동 출석 취소: 키(또는 관리자 토큰) 필요 ──────────────
create or replace function public.undo_recent_attendance(p_id bigint, p_key uuid, p_token uuid default null)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare a attendance; n int;
begin
  select * into a from attendance where id = p_id;
  if a.id is null then return false; end if;
  if not cosmos_admin_token_ok(p_token)
     and not exists (select 1 from sessions s where s.세션id = a.세션id and cosmos_key_covers(p_key, s.날짜, s.장소)) then
    return false;
  end if;
  delete from attendance
   where id = p_id and 사후여부 = false and 메모 = '수동'
     and 생성일시 > now() - interval '15 minutes';
  get diagnostics n = row_count;
  return n > 0;
end
$function$;

revoke execute on function public.cosmos_key_covers(uuid, date, text) from public, anon, authenticated;
revoke execute on function public.cosmos_admin_token_ok(uuid) from public, anon, authenticated;
grant execute on function public.student_check_in(text, text, text, text) to anon, authenticated;
grant execute on function public.teacher_check_in(text, text, uuid, uuid, boolean, text) to anon, authenticated;
grant execute on function public.undo_recent_attendance(bigint, uuid, uuid) to anon, authenticated;
