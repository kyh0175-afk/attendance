-- ═══════════════════════════════════════════════════════════════
--  v3 코어 RPC — 라이브 정의 백업 (2026-08-01 덤프)
--
--  ★ 이 함수들은 대시보드에서 직접 생성돼 레포에 소스가 없었다.
--    Free 플랜은 DB 백업이 없으므로 이 파일이 유일한 복원 수단이다.
--    이후 수정은 반드시 이 파일을 갱신할 것.
--
--  덤프 명령:
--    select string_agg(pg_get_functiondef(p.oid), E'\n\n' order by p.proname)
--    from pg_proc p
--    where p.pronamespace = 'public'::regnamespace
--      and p.proname in ('is_staff','is_admin','create_v3_session','issue_exit_code',
--                        'finalize_session','check_in','check_out','staff_manual_attendance');
--
--  현재 상태: 2026-08-01 core_rpc_fix.sql 적용 완료본
--    · check_in           만료시각 검증 추가 · 날짜를 세션 날짜로
--    · create_v3_session  같은 장소 세션은 날짜 불문 닫기 · 입실코드 중복 방지 · KST 날짜
--    · issue_exit_code    expires_at을 timestamptz로 반환
-- ═══════════════════════════════════════════════════════════════


CREATE OR REPLACE FUNCTION public.check_in(p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_hakbun text; v_sess record; v_name text;
begin
  v_hakbun := split_part(coalesce(auth.email(), ''), '@', 1);
  if v_hakbun !~ '^[0-9]{4,6}$' then raise exception '로그인이 필요합니다' using errcode='28000'; end if;

  select * into v_sess from sessions
   where 입실코드 = p_code
     and 활성 = true
     and (만료시각 is null or 만료시각 > now())     -- 2026-08-01 추가: 좀비 코드 2차 방어선
   order by 날짜 desc limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'msg', '입실 코드가 맞지 않아요. 칠판을 확인해주세요');
  end if;

  select 이름 into v_name from students where 학번 = v_hakbun order by 활성 desc limit 1;
  begin
    insert into attendance (세션id, 학번, 이름, 날짜, 원래시각, 사후여부, 프로그램, 장소, 교사, 상태)
    values (v_sess.세션id, v_hakbun, coalesce(v_name, v_hakbun), v_sess.날짜,   -- 2026-08-01: current_date → 세션 날짜
            (now() at time zone 'Asia/Seoul')::time, false,
            v_sess.프로그램, v_sess.장소, v_sess.교사, '출석');
  exception when unique_violation then
    return jsonb_build_object('ok', true, 'already', true, '프로그램', v_sess.프로그램, '장소', v_sess.장소);
  end;
  return jsonb_build_object('ok', true, '프로그램', v_sess.프로그램, '장소', v_sess.장소);
end$function$;


CREATE OR REPLACE FUNCTION public.check_out(p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_hakbun text; v_sess record; v_n int;
begin
  v_hakbun := split_part(coalesce(auth.email(),''), '@', 1);
  if v_hakbun !~ '^[0-9]{4,6}$' then raise exception '로그인이 필요합니다' using errcode='28000'; end if;
  select * into v_sess from sessions where 퇴실코드 = p_code and 퇴실코드만료 > now() order by 날짜 desc limit 1;
  if not found then return jsonb_build_object('ok',false,'msg','퇴실 코드가 맞지 않거나 시간이 지났어요'); end if;
  update attendance set 퇴실시각 = now(), 퇴실방식 = '코드'
   where 세션id = v_sess.세션id and 학번 = v_hakbun and 퇴실시각 is null;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    if exists(select 1 from attendance where 세션id=v_sess.세션id and 학번=v_hakbun) then
      return jsonb_build_object('ok',true,'already',true);
    end if;
    return jsonb_build_object('ok',false,'msg','입실 기록이 없어요. 먼저 입실했는지 확인해주세요');
  end if;
  return jsonb_build_object('ok',true);
end$function$;


CREATE OR REPLACE FUNCTION public.create_v3_session(p_program text, p_room text, p_teacher text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_id text; v_code text; v_today date; i int;
begin
  if not is_staff() then raise exception '교사 인증이 필요합니다' using errcode='42501'; end if;

  v_today := (now() at time zone 'Asia/Seoul')::date;

  -- 2026-08-01: `날짜 = current_date` 제거 — 어제 이전 좀비 세션도 함께 닫는다
  update sessions set 활성 = false, 종료시각 = coalesce(종료시각, now())
   where 장소 = p_room and 활성 = true;

  v_id := to_char(now() at time zone 'Asia/Seoul', 'YYYYMMDDHH24MISS') || '_' || p_room;

  -- 2026-08-01: 활성 세션 간 입실코드 중복 방지 (DESIGN 전제 실현)
  v_code := null;
  for i in 1..50 loop
    v_code := lpad((floor(random() * 10000))::int::text, 4, '0');
    exit when not exists (
      select 1 from sessions where 입실코드 = v_code and 활성 = true
    );
    v_code := null;
  end loop;
  if v_code is null then
    raise exception '입실 코드를 만들지 못했습니다. 잠시 후 다시 시도해주세요';
  end if;

  insert into sessions (세션id, 날짜, 활성, 만료시각, 프로그램, 장소, 교사, 입실코드)
    values (v_id, v_today, true, now() + interval '5 hours', p_program, p_room, p_teacher, v_code);

  return jsonb_build_object('session_id', v_id, 'entry_code', v_code);
end$function$;


CREATE OR REPLACE FUNCTION public.finalize_session(p_session_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_missing int;
begin
  if not is_staff() then raise exception '교사 인증이 필요합니다' using errcode='42501'; end if;
  update attendance set 상태 = '퇴실미확인'
   where 세션id = p_session_id and 퇴실시각 is null and 사후여부 = false and coalesce(상태,'출석') = '출석';
  get diagnostics v_missing = row_count;
  update sessions set 활성 = false, 종료시각 = now() where 세션id = p_session_id;
  return jsonb_build_object('ok', true, 'missing', v_missing);
end$function$;


CREATE OR REPLACE FUNCTION public.is_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from public.staff s
    where s.user_id = auth.uid() and s.role = 'admin'
  )
$function$;


CREATE OR REPLACE FUNCTION public.is_staff()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists(select 1 from staff where user_id = auth.uid());
$function$;


CREATE OR REPLACE FUNCTION public.issue_exit_code(p_session_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_code text; v_exp timestamptz;
begin
  if not is_staff() then raise exception '교사 인증이 필요합니다' using errcode='42501'; end if;

  v_code := lpad((floor(random() * 10000))::int::text, 4, '0');
  -- 2026-08-01: 'HH24:MI' 문자열 → 실제 timestamptz. 교사 화면이 정확히 파싱한다.
  update sessions
     set 퇴실코드 = v_code,
         퇴실코드만료 = now() + interval '10 minutes'
   where 세션id = p_session_id
  returning 퇴실코드만료 into v_exp;
  if not found then raise exception '세션을 찾을 수 없습니다'; end if;

  return jsonb_build_object('code', v_code, 'expires_at', v_exp);
end$function$;


CREATE OR REPLACE FUNCTION public.staff_manual_attendance(p_session_id text, p_hakbun text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s record; st record; new_id bigint;
begin
  if not public.is_staff() then raise exception '교사 권한이 필요합니다'; end if;
  if p_hakbun !~ '^\d{5}$' then raise exception '학번은 5자리 숫자여야 합니다'; end if;
  select "세션id", "프로그램", "장소", "교사", "날짜" into s
    from public.sessions where "세션id" = p_session_id limit 1;
  if s."세션id" is null then raise exception '세션을 찾을 수 없습니다'; end if;
  select "이름", "장소" into st
    from public.students where "학번" = p_hakbun and "프로그램" = s."프로그램" limit 1;
  if st."이름" is null then
    select "이름", null::text as "장소" into st
      from public.students where "학번" = p_hakbun limit 1;
  end if;
  if st."이름" is null then
    raise exception '명단에 없는 학번입니다';
  end if;
  begin
    insert into public.attendance
      ("세션id", "학번", "이름", "날짜", "원래시각", "처리시각", "사후여부", "프로그램", "장소", "교사", "상태", "메모")
    values
      (s."세션id", p_hakbun, st."이름", s."날짜",
       (now() at time zone 'Asia/Seoul')::time, now(), false, s."프로그램",
       coalesce(st."장소", s."장소"), s."교사", '출석', '수동입실')
    returning id into new_id;
  exception when unique_violation then
    return jsonb_build_object('ok', true, 'already', true, 'name', st."이름");
  end;
  return jsonb_build_object('ok', true, 'id', new_id, 'name', st."이름");
end $function$;
