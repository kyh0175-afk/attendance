-- 2026-10-14 보안 2단계(b): anon 의 출석 직접 INSERT 차단 + 세션 키 열 숨김
-- 적용: supabase MCP apply_migration (security_2b_lock_attendance_insert)
-- 전제: 2a + 프런트(2dbf4d5)가 배포돼 모든 출석 쓰기가 RPC 로 감.
--
-- 되돌리기:
--   create policy anon_insert_attendance on public.attendance for insert to anon with check (true);
--   grant select, update on public.sessions to anon;
--   (옛 undo_recent_attendance(bigint) 는 2026-10-14_security_1 이전 정의를 git 기록에서 복구)

drop policy if exists anon_insert_attendance on public.attendance;
revoke insert, update, delete on public.attendance from anon;

-- 키 없이 지우던 옛 취소 함수 폐기(새 함수는 (id, key, token))
drop function if exists public.undo_recent_attendance(bigint);

-- sessions: session_key 는 anon 이 읽거나 바꿀 수 없게(만들 때 넣는 것만 허용)
revoke select, update on public.sessions from anon;
grant select (id, 세션id, 프로그램, 장소, 교사, 날짜, 시작시각, 만료시각, 종료시각, 활성, 연장됨, 입실코드)
  on public.sessions to anon;
grant update (활성, 종료시각, 교사, 만료시각, 연장됨) on public.sessions to anon;

-- 마감 세션 거부 트리거: 사후여부=true 우회는 서버 함수(SECURITY DEFINER) 안에서만
create or replace function public.trg_attendance_reject_closed_session()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $function$
declare
  s_active   boolean;
  s_expire   timestamptz;
  s_end      timestamptz;
  found_sess boolean := false;
begin
  if NEW.사후여부 is true and current_user not in ('anon', 'authenticated') then
    return NEW;
  end if;

  select true, s.활성, s.만료시각, s.종료시각
    into found_sess, s_active, s_expire, s_end
  from sessions s
  where s.세션id = NEW.세션id
  limit 1;

  if found_sess then
    if s_active is not true
       or s_end is not null
       or (s_expire is not null and s_expire < now()) then
      if NEW.메모 = '카드' and current_setting('cosmos.card_queued', true) = 'on' then
        return NEW;
      end if;
      raise exception '마감되었거나 만료된 세션에는 출석할 수 없습니다 (세션 %).', NEW.세션id
        using errcode = 'check_violation';
    end if;
  end if;

  return NEW;
end;
$function$;
revoke execute on function public.trg_attendance_reject_closed_session() from public, anon, authenticated;

revoke execute on function public.trg_attendance_reject_closed_session() from public, anon, authenticated;
