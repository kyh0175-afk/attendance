-- ※ 라이브 미적용 초안(2026-10-18 확인: 현재 정책 = reopen 파일의 전체 공개 읽기).
--   공개 레포라 학교 공인 IP 는 '<학교 공인 IP>' 로 가렸다. 적용할 때는 system_settings 에 school_public_ips 를 먼저 넣고
--   아래 기본값 자리를 실제 값으로 바꾼다(원본 = 로컬 _리뷰\2026-10-16_school_ip_read_원본.sql, git 제외).
-- 2026-10-16 학생 명단·출석 기록 읽기: 전체 공개(오늘 오전 되돌림) → 학교 공인 IP 또는 세션 키·관리자
-- 이유: anon 전체 읽기 = 공개 레포의 publishable 키로 인터넷 누구나 명단·출석 이력 조회(보안 검토 10/16).
--       10/14 범위 정책은 세션을 연 기기만 명단이 보여 같은 장소 쌍의 다른 칠판이 막혔음(roster_load_fail no-key).
-- 방식: 학교 칠판은 모두 같은 공인 IP 로 나간다 → Cloudflare 가 넣는 cf-connecting-ip(클라이언트가 위조하면 Cloudflare 가 403, 실측)로 판정.
--       x-forwarded-for 는 위조 값이 앞에 붙으므로 쓰지 않는다(실측).
-- 학교 IP 바뀌면: system_settings 의 school_public_ips(쉼표) 값만 고친다(없으면 기본 <학교 공인 IP>).
-- 되돌리기(전체 공개로) = 2026-10-16_reopen_students_attendance_read.sql 의 create policy 두 줄.

drop function if exists public.tmp_probe_ip();

create or replace function public.cosmos_req_school() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(cosmos_hdr('cf-connecting-ip'), '') = any (
    string_to_array(replace(coalesce(
      (select value from system_settings where key = 'school_public_ips'), '<학교 공인 IP>'), ' ', ''), ','));
$$;
revoke all on function public.cosmos_req_school() from public;
grant execute on function public.cosmos_req_school() to anon, authenticated;

drop policy if exists anon_read_students on public.students;
drop policy if exists anon_read_students_scoped on public.students;
create policy anon_read_students_scoped on public.students for select to anon
  using ((select cosmos_req_admin()) or (select cosmos_req_school()) or (select cosmos_req_rooms()) @> array[장소]);

drop policy if exists anon_read_attendance on public.attendance;
drop policy if exists anon_read_attendance_scoped on public.attendance;
create policy anon_read_attendance_scoped on public.attendance for select to anon
  using ((select cosmos_req_admin()) or (select cosmos_req_school()) or (select cosmos_req_rooms()) @> array[장소]);
