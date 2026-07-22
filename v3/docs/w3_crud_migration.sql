-- ============================================================
-- 코스모스 출석 v3 — W3 라운드2: 관리자 CRUD 마이그레이션 (2026-07-22)
-- 명단 CRUD + 기록 관리(사후출석·상태정정·삭제) 서버측 RPC 8종
-- 전부 SECURITY DEFINER + is_admin() 게이트 + anon/public EXECUTE 회수
-- 적용: Supabase MCP apply_migration 또는 SQL Editor. 재실행 안전.
-- 전제: w3_migration.sql (is_admin 등) 적용 완료
-- ============================================================

-- 1) 학생 추가/수정 (학번×프로그램 단위 upsert — v2 admin_upsert_student와 동등, Auth 게이트판)
create or replace function public.admin_upsert_student_v3(
  p_hakbun text, p_program text, p_name text, p_room text, p_days text[]
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.is_admin() then raise exception '관리자 권한이 필요합니다'; end if;
  if p_hakbun !~ '^\d{5}$' then raise exception '학번은 5자리 숫자여야 합니다'; end if;
  if coalesce(p_name, '') = '' or coalesce(p_program, '') = '' or coalesce(p_room, '') = '' then
    raise exception '이름·프로그램·장소는 필수입니다';
  end if;
  update public.students
     set "이름" = p_name, "장소" = p_room, "출석요일" = p_days, "활성" = true, "수정일시" = now()
   where "학번" = p_hakbun and "프로그램" = p_program;
  get diagnostics n = row_count;
  if n = 0 then
    insert into public.students ("학번", "프로그램", "이름", "장소", "출석요일", "활성")
    values (p_hakbun, p_program, p_name, p_room, p_days, true);
    return jsonb_build_object('ok', true, 'mode', 'inserted');
  end if;
  return jsonb_build_object('ok', true, 'mode', 'updated', 'updated', n);
end $$;
revoke execute on function public.admin_upsert_student_v3(text, text, text, text, text[]) from public;
revoke execute on function public.admin_upsert_student_v3(text, text, text, text, text[]) from anon;
grant execute on function public.admin_upsert_student_v3(text, text, text, text, text[]) to authenticated;

-- 2) 엑셀 일괄 upsert — [{학번,프로그램,이름,장소,출석요일:[..]|null}, ...]
create or replace function public.admin_bulk_upsert_students_v3(p_students jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  rec jsonb; n int; ins int := 0; upd int := 0; bad int := 0;
  v_hakbun text; v_program text; v_name text; v_room text; v_days text[];
begin
  if not public.is_admin() then raise exception '관리자 권한이 필요합니다'; end if;
  if jsonb_typeof(p_students) is distinct from 'array' then raise exception 'p_students는 배열이어야 합니다'; end if;
  for rec in select * from jsonb_array_elements(p_students) loop
    v_hakbun  := rec->>'학번';
    v_program := rec->>'프로그램';
    v_name    := rec->>'이름';
    v_room    := rec->>'장소';
    -- 출석요일은 배열|null만 허용 — 스칼라/객체면 그 행만 skip(배치 전체 중단 방지)
    if rec->'출석요일' is null or jsonb_typeof(rec->'출석요일') = 'null' then v_days := null;
    elsif jsonb_typeof(rec->'출석요일') = 'array' then
      select array(select jsonb_array_elements_text(rec->'출석요일')) into v_days;
    else bad := bad + 1; continue;
    end if;
    if v_hakbun !~ '^\d{5}$' or coalesce(v_name, '') = '' or coalesce(v_program, '') = '' or coalesce(v_room, '') = '' then
      bad := bad + 1; continue;
    end if;
    update public.students
       set "이름" = v_name, "장소" = v_room, "출석요일" = v_days, "활성" = true, "수정일시" = now()
     where "학번" = v_hakbun and "프로그램" = v_program;
    get diagnostics n = row_count;
    if n = 0 then
      insert into public.students ("학번", "프로그램", "이름", "장소", "출석요일", "활성")
      values (v_hakbun, v_program, v_name, v_room, v_days, true);
      ins := ins + 1;
    else
      upd := upd + n;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'inserted', ins, 'updated', upd, 'skipped', bad);
end $$;
revoke execute on function public.admin_bulk_upsert_students_v3(jsonb) from public;
revoke execute on function public.admin_bulk_upsert_students_v3(jsonb) from anon;
grant execute on function public.admin_bulk_upsert_students_v3(jsonb) to authenticated;

-- 3) 프로그램 단위 활성/비활성 (학생 단위는 기존 admin_set_student_active_v3)
create or replace function public.admin_set_student_active_program_v3(
  p_hakbun text, p_program text, p_active boolean
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.is_admin() then raise exception '관리자 권한이 필요합니다'; end if;
  update public.students set "활성" = p_active, "수정일시" = now()
   where "학번" = p_hakbun and "프로그램" = p_program;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'updated', n);
end $$;
revoke execute on function public.admin_set_student_active_program_v3(text, text, boolean) from public;
revoke execute on function public.admin_set_student_active_program_v3(text, text, boolean) from anon;
grant execute on function public.admin_set_student_active_program_v3(text, text, boolean) to authenticated;

-- 4) 학생 삭제 — p_program null이면 전 프로그램. p_delete_attendance=true면 출석 기록까지(비가역!).
create or replace function public.admin_delete_student_v3(
  p_hakbun text, p_program text default null, p_delete_attendance boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ns int; na int := 0;
begin
  if not public.is_admin() then raise exception '관리자 권한이 필요합니다'; end if;
  if p_delete_attendance then
    delete from public.attendance
     where "학번" = p_hakbun and (p_program is null or "프로그램" = p_program);
    get diagnostics na = row_count;
  end if;
  delete from public.students
   where "학번" = p_hakbun and (p_program is null or "프로그램" = p_program);
  get diagnostics ns = row_count;
  return jsonb_build_object('ok', true, 'students_deleted', ns, 'attendance_deleted', na);
end $$;
revoke execute on function public.admin_delete_student_v3(text, text, boolean) from public;
revoke execute on function public.admin_delete_student_v3(text, text, boolean) from anon;
grant execute on function public.admin_delete_student_v3(text, text, boolean) to authenticated;

-- 5) 사후 출석 추가 — 기존 세션에 붙인다 (v2 lateAdd와 동등: 사후여부=true, 원래시각 null, 처리시각 now)
--    학생 등록 장소 우선(sibling 세션 대비), 명단에 없는 학번은 거부(명단 CRUD로 먼저 추가).
create or replace function public.admin_add_attendance_v3(p_session_id text, p_hakbun text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s record; st record; new_id bigint;
begin
  if not public.is_admin() then raise exception '관리자 권한이 필요합니다'; end if;
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
    raise exception '명단에 없는 학번입니다 — 명단 탭에서 먼저 추가해주세요';
  end if;
  begin
    insert into public.attendance
      ("세션id", "학번", "이름", "날짜", "원래시각", "처리시각", "사후여부", "프로그램", "장소", "교사", "상태")
    values
      (s."세션id", p_hakbun, st."이름", s."날짜", null, now(), true, s."프로그램",
       coalesce(st."장소", s."장소"), s."교사", '출석')
    returning id into new_id;
  exception when unique_violation then
    return jsonb_build_object('ok', true, 'already', true);
  end;
  return jsonb_build_object('ok', true, 'id', new_id, 'name', st."이름");
end $$;
revoke execute on function public.admin_add_attendance_v3(text, text) from public;
revoke execute on function public.admin_add_attendance_v3(text, text) from anon;
grant execute on function public.admin_add_attendance_v3(text, text) to authenticated;

-- 6) 출석 상태 정정 — '조퇴'로 바꾸면 퇴실방식/퇴실시각 자동 기입
create or replace function public.admin_update_attendance_status_v3(p_id bigint, p_status text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.is_admin() then raise exception '관리자 권한이 필요합니다'; end if;
  if p_status not in ('출석', '조퇴', '퇴실미확인', '결석') then
    raise exception '허용되지 않는 상태값입니다';
  end if;
  if p_status = '조퇴' then
    update public.attendance
       set "상태" = p_status, "퇴실방식" = '조퇴', "퇴실시각" = coalesce("퇴실시각", now())
     where id = p_id;
  else
    update public.attendance set "상태" = p_status where id = p_id;
  end if;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', n > 0, 'updated', n);
end $$;
revoke execute on function public.admin_update_attendance_status_v3(bigint, text) from public;
revoke execute on function public.admin_update_attendance_status_v3(bigint, text) from anon;
grant execute on function public.admin_update_attendance_status_v3(bigint, text) to authenticated;

-- 7) 출석 개별 삭제
create or replace function public.admin_delete_attendance_v3(p_id bigint)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.is_admin() then raise exception '관리자 권한이 필요합니다'; end if;
  delete from public.attendance where id = p_id;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', n > 0, 'deleted', n);
end $$;
revoke execute on function public.admin_delete_attendance_v3(bigint) from public;
revoke execute on function public.admin_delete_attendance_v3(bigint) from anon;
grant execute on function public.admin_delete_attendance_v3(bigint) to authenticated;

-- 8) 세션 삭제 — sibling 행 포함 전체 + (기본) 그 세션의 출석 기록까지
create or replace function public.admin_delete_session_v3(p_session_id text, p_delete_attendance boolean default true)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare ns int; na int := 0;
begin
  if not public.is_admin() then raise exception '관리자 권한이 필요합니다'; end if;
  if p_delete_attendance then
    delete from public.attendance where "세션id" = p_session_id;
    get diagnostics na = row_count;
  end if;
  delete from public.sessions where "세션id" = p_session_id;
  get diagnostics ns = row_count;
  return jsonb_build_object('ok', true, 'sessions_deleted', ns, 'attendance_deleted', na);
end $$;
revoke execute on function public.admin_delete_session_v3(text, boolean) from public;
revoke execute on function public.admin_delete_session_v3(text, boolean) from anon;
grant execute on function public.admin_delete_session_v3(text, boolean) to authenticated;
