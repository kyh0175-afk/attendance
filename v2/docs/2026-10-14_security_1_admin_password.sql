-- 2026-10-14 보안 1단계: 관리자 비밀번호 해시화 + 로그인 실패 제한 + anon 실행 권한 회수
-- 적용: supabase MCP apply_migration (security_1_admin_password)
-- 비밀번호 값·해시는 이 파일에 없다. 해시는 별도 execute_sql 로
--   update system_settings set value = '<bcrypt $2a$ 해시>' where key = 'admin_password';
-- 로 넣었다(평문 비밀번호는 교사 PC의 코스모스_관리자비밀번호.txt 에만 있음).
--
-- 되돌리기(rollback) — 맨 아래 주석 참고.

-- 1) 로그인 실패 기록(클라이언트 IP 기준 + 전체)
create table if not exists public.admin_login_failures (
  id     bigserial primary key,
  at     timestamptz not null default now(),
  client text not null
);
create index if not exists admin_login_failures_at_idx on public.admin_login_failures (at);
alter table public.admin_login_failures enable row level security;
revoke all on public.admin_login_failures from anon, authenticated, public;

-- 2) admin_login: bcrypt 대조 + 10분 5회(클라이언트) / 10분 50회(전체) 제한
--    시그니처·반환형(uuid, 실패 시 null) 그대로 → 프런트 수정 불필요
create or replace function public.admin_login(p_password text)
returns uuid
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  t        uuid;
  h        text;
  v_client text;
  v_hdr    json;
begin
  begin
    v_hdr := nullif(current_setting('request.headers', true), '')::json;
  exception when others then
    v_hdr := null;
  end;
  v_client := coalesce(
    nullif(trim(split_part(coalesce(v_hdr->>'x-forwarded-for', ''), ',', 1)), ''),
    nullif(v_hdr->>'cf-connecting-ip', ''),
    'unknown');

  delete from admin_login_failures where at < now() - interval '1 day';

  if (select count(*) from admin_login_failures
       where client = v_client and at > now() - interval '10 minutes') >= 5
     or (select count(*) from admin_login_failures
       where at > now() - interval '10 minutes') >= 50 then
    raise exception '로그인 시도가 너무 많아요. 10분 뒤 다시 시도해 주세요.'
      using errcode = 'P0001';
  end if;

  select value into h from system_settings where key = 'admin_password';
  if p_password is null or h is null or h !~ '^\$2[abxy]\$'
     or extensions.crypt(p_password, h) <> h then
    insert into admin_login_failures(client) values (v_client);
    return null;
  end if;

  delete from admin_sessions where expires_at < now();  -- 만료 청소
  insert into admin_sessions default values returning token into t;
  return t;
end
$function$;

-- 3) 평문 비교 RPC 폐기(프런트 진단 화면만 쓰던 것)
revoke execute on function public.verify_admin_password(text) from public, anon, authenticated;
create or replace function public.verify_admin_password(p_input text)
returns boolean
language sql
security definer
set search_path = public, extensions, pg_temp
as $function$
  select false;
$function$;
revoke execute on function public.verify_admin_password(text) from public, anon, authenticated;

-- 4) 프런트가 쓰지 않는 위험 함수·트리거 함수 anon 실행 회수
revoke execute on function public.delete_seat_request(bigint) from public, anon, authenticated;
revoke execute on function public.bulk_upsert_students(jsonb) from public, anon, authenticated;
revoke execute on function public.cleanup_old_teacher_logs() from public, anon, authenticated;
revoke execute on function public.log_sessions_changes() from public, anon, authenticated;
revoke execute on function public.touch_cosmos_modified() from public, anon, authenticated;
revoke execute on function public.trg_attendance_authoritative_time() from public, anon, authenticated;
revoke execute on function public.trg_attendance_reject_closed_session() from public, anon, authenticated;

-- 5) 유출된 옛 비밀번호로 받은 관리자 토큰 무효화
delete from public.admin_sessions;

-- ── 되돌리기 ──────────────────────────────────────────────
-- (옛 평문 비밀번호로 돌아가는 것은 권장하지 않음. 해시를 새로 넣으면 됨:)
--   update system_settings set value = extensions.crypt('<새 비밀번호>', extensions.gen_salt('bf', 10))
--    where key = 'admin_password';
-- 제한이 잘못 걸렸을 때:  delete from public.admin_login_failures;
-- 회수한 권한 되돌리기:   grant execute on function public.<함수>(<인자>) to anon;
