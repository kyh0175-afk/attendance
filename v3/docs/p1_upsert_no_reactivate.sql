-- P1 수정(2026-08-11, 라이브 적용 완료): admin_upsert_student_v3 재활성 버그
-- 증상: UPDATE가 "활성"=true를 강제 → 전출(비활성) 학생의 이름 오타 수정만으로 등록 부활(통계 분모 오염)
-- 수정: UPDATE에서 "활성" 제거(기존값 보존). 신규 INSERT는 활성=true 유지. 재활성=별도 토글 RPC만.
-- 권한: CREATE OR REPLACE는 기존 GRANT 보존(anon 회수 상태 유지 확인됨).

create or replace function public.admin_upsert_student_v3(p_hakbun text, p_program text, p_name text, p_room text, p_days text[])
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare n int;
begin
  if not public.is_admin() then raise exception '관리자 권한이 필요합니다'; end if;
  if p_hakbun !~ '^\d{5}$' then raise exception '학번은 5자리 숫자여야 합니다'; end if;
  if coalesce(p_name, '') = '' or coalesce(p_program, '') = '' or coalesce(p_room, '') = '' then
    raise exception '이름·프로그램·장소는 필수입니다';
  end if;
  update public.students
     set "이름" = p_name, "장소" = p_room, "출석요일" = p_days, "수정일시" = now()
   where "학번" = p_hakbun and "프로그램" = p_program;
  get diagnostics n = row_count;
  if n = 0 then
    insert into public.students ("학번", "프로그램", "이름", "장소", "출석요일", "활성")
    values (p_hakbun, p_program, p_name, p_room, p_days, true);
    return jsonb_build_object('ok', true, 'mode', 'inserted');
  end if;
  return jsonb_build_object('ok', true, 'mode', 'updated', 'updated', n);
end $function$;

-- 원복(구버전 — 활성 강제 포함):
--   update ... set "이름"=p_name, "장소"=p_room, "출석요일"=p_days, "활성"=true, "수정일시"=now() ...
