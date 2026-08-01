-- ═══════════════════════════════════════════════════════════════
--  v3 코어 RPC 결함 수정 (2026-08-01)
--  원본 정의는 core_rpc.sql · 여기 적용 후 core_rpc.sql도 갱신할 것
--
--  SQL Editor에 통째로 붙여넣어 실행. 섹션 0(정리)은 1회성,
--  섹션 1~3(함수 교체)은 몇 번을 실행해도 무해하다.
-- ═══════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────
-- 0. 좀비 세션 즉시 정리 (1회성) ★ 가장 급함
-- ───────────────────────────────────────────────────────────────
-- 문제: 어제 이전 세션이 활성=true로 남아 있고 입실코드도 그대로 유효하다.
--       학생이 7/22 아우름 코드(9839)를 지금 입력하면 그 세션에 입실된다.
--       (check_in은 활성=true만 보고 날짜·만료시각을 보지 않음)
--
-- 마감(finalize_session)이 아니라 '닫기'만 한다. 미퇴실자를 '퇴실미확인'으로
-- 마킹하면 7월 테스트 기록이 통계에 잡히므로, 여기서는 활성만 내린다.
update public.sessions
   set "활성" = false,
       "종료시각" = coalesce("종료시각", now())
 where "활성" = true
   and "날짜" < (now() at time zone 'Asia/Seoul')::date;

-- 확인 — 오늘 것만 남아야 한다
select "세션id", "날짜", "장소", "프로그램", "입실코드"
from public.sessions where "활성" = true
order by "날짜" desc, "장소";


-- ───────────────────────────────────────────────────────────────
-- 1. create_v3_session — 좀비 발생 원인 + 입실코드 중복 방지
-- ───────────────────────────────────────────────────────────────
-- 변경점 3가지:
--  (a) 기존 세션 닫기 조건에서 `날짜 = current_date` 제거
--      → 어제 이전에 마감 안 된 같은 장소 세션도 함께 닫힌다. 좀비 재발 차단.
--  (b) 입실코드 중복 방지 루프 추가
--      → DESIGN.md는 "동시 활성 세션 간 중복 금지(서버가 보장)"이라 했으나
--        실제로는 랜덤 4자리를 검사 없이 넣고 있었다. check_in이
--        `order by 날짜 desc limit 1`로 하나만 고르므로, 충돌 시 학생이
--        엉뚱한 세션에 입실될 수 있다.
--  (c) 날짜를 KST 기준으로 (current_date는 서버 TZ=UTC 기준)
create or replace function public.create_v3_session(p_program text, p_room text, p_teacher text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_id text; v_code text; v_today date; i int;
begin
  if not is_staff() then raise exception '교사 인증이 필요합니다' using errcode='42501'; end if;

  v_today := (now() at time zone 'Asia/Seoul')::date;

  -- (a) 같은 장소의 열린 세션은 날짜 불문 전부 닫는다
  update sessions set 활성 = false, 종료시각 = coalesce(종료시각, now())
   where 장소 = p_room and 활성 = true;

  v_id := to_char(now() at time zone 'Asia/Seoul', 'YYYYMMDDHH24MISS') || '_' || p_room;

  -- (b) 활성 세션과 겹치지 않는 코드가 나올 때까지 재시도
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

revoke execute on function public.create_v3_session(text, text, text) from public;
revoke execute on function public.create_v3_session(text, text, text) from anon;
grant  execute on function public.create_v3_session(text, text, text) to authenticated;


-- ───────────────────────────────────────────────────────────────
-- 2. check_in — 만료시각 검증 (2차 방어선)
-- ───────────────────────────────────────────────────────────────
-- sessions.만료시각(생성 시 +5시간)이 지금까지 아무 데서도 검사되지 않았다.
-- 1번으로 좀비 재발은 막히지만, 세션을 닫지 못한 사고가 또 나더라도
-- 5시간 뒤에는 코드가 스스로 죽도록 한다.
-- (운영 프로그램 최장 4시간 — 토요일 08:30~12:30 — 이라 정상 운영엔 영향 없음)
create or replace function public.check_in(p_code text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_hakbun text; v_sess record; v_name text;
begin
  v_hakbun := split_part(coalesce(auth.email(), ''), '@', 1);
  if v_hakbun !~ '^[0-9]{4,6}$' then raise exception '로그인이 필요합니다' using errcode='28000'; end if;

  select * into v_sess from sessions
   where 입실코드 = p_code
     and 활성 = true
     and (만료시각 is null or 만료시각 > now())     -- ★ 추가
   order by 날짜 desc limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'msg', '입실 코드가 맞지 않아요. 칠판을 확인해주세요');
  end if;

  select 이름 into v_name from students where 학번 = v_hakbun order by 활성 desc limit 1;
  begin
    insert into attendance (세션id, 학번, 이름, 날짜, 원래시각, 사후여부, 프로그램, 장소, 교사, 상태)
    values (v_sess.세션id, v_hakbun, coalesce(v_name, v_hakbun), v_sess.날짜,   -- ★ 세션의 날짜를 따름
            (now() at time zone 'Asia/Seoul')::time, false,
            v_sess.프로그램, v_sess.장소, v_sess.교사, '출석');
  exception when unique_violation then
    return jsonb_build_object('ok', true, 'already', true, '프로그램', v_sess.프로그램, '장소', v_sess.장소);
  end;
  return jsonb_build_object('ok', true, '프로그램', v_sess.프로그램, '장소', v_sess.장소);
end$function$;

revoke execute on function public.check_in(text) from public;
revoke execute on function public.check_in(text) from anon;
grant  execute on function public.check_in(text) to authenticated;


-- ───────────────────────────────────────────────────────────────
-- 3. issue_exit_code — expires_at을 실제 시각 값으로
-- ───────────────────────────────────────────────────────────────
-- 기존: to_char(..., 'HH24:MI') → "13:22" 같은 문자열을 반환했다.
--       교사 화면의 `new Date(res.expires_at)`가 Invalid Date가 되어
--       조용히 클라 추정치(+10분)로 폴백하고 있었다(동작은 정상).
-- 변경: timestamptz를 그대로 담아 ISO 8601로 직렬화 → 클라가 정확히 파싱.
--       UPDATE의 실제 저장값을 돌려주므로 서버와 화면이 항상 일치한다.
create or replace function public.issue_exit_code(p_session_id text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_code text; v_exp timestamptz;
begin
  if not is_staff() then raise exception '교사 인증이 필요합니다' using errcode='42501'; end if;

  v_code := lpad((floor(random() * 10000))::int::text, 4, '0');
  update sessions
     set 퇴실코드 = v_code,
         퇴실코드만료 = now() + interval '10 minutes'
   where 세션id = p_session_id
  returning 퇴실코드만료 into v_exp;
  if not found then raise exception '세션을 찾을 수 없습니다'; end if;

  return jsonb_build_object('code', v_code, 'expires_at', v_exp);
end$function$;

revoke execute on function public.issue_exit_code(text) from public;
revoke execute on function public.issue_exit_code(text) from anon;
grant  execute on function public.issue_exit_code(text) to authenticated;


-- ───────────────────────────────────────────────────────────────
-- 4. 적용 확인
-- ───────────────────────────────────────────────────────────────
select p.proname as "함수",
       has_function_privilege('anon',          p.oid, 'EXECUTE') as "anon",
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as "authenticated"
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname in ('create_v3_session', 'check_in', 'issue_exit_code')
order by 1;

-- 적용 후 라이브 스모크:
--  1) 교사: 세션 시작 → 입실코드가 기존 활성 코드와 겹치지 않는지
--  2) 학생: 입실 → 정상
--  3) 교사: 퇴실코드 발급 → 카운트다운이 "10:00 남음"에서 시작하는지
--     (이전엔 클라 추정이라 응답 지연만큼 길게 표시됐다)
--  4) 학생: 퇴실 → 정상
--  5) 교사: 같은 장소로 새 세션 시작 → 이전 세션이 활성 목록에서 사라지는지
