-- ============================================================
-- 코스모스 출석 v3 — W3 관리자 마이그레이션 (2026-07-22)
-- 적용: Supabase Dashboard → SQL Editor → 전체 붙여넣기 → Run
-- 성격: 추가만(additive). 기존 정책·함수 무변경. 재실행 안전(idempotent).
-- 전제: staff 테이블 + is_staff() 존재 (W1에서 생성됨)
-- ============================================================

-- 1) is_admin() — staff.role='admin' 여부 (SECURITY DEFINER, RLS 우회 판정)
create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.staff s
    where s.user_id = auth.uid() and s.role = 'admin'
  )
$$;
-- 함수 EXECUTE는 PUBLIC 기본부여 — public과 anon 둘 다 회수해야 함 (v2 보안트랙 교훈)
revoke execute on function public.is_admin() from public;
revoke execute on function public.is_admin() from anon;
grant execute on function public.is_admin() to authenticated;

-- 2) staff 본인 행 읽기 — 로그인한 교직원이 자기 role을 확인하는 용도
--    (다른 staff 행은 계속 비공개, anon은 계속 전체 차단)
--    ⚠️ v2 하드닝 때 staff는 테이블 GRANT 자체가 회수됨(실측: permission denied)
--       → RLS 정책만으론 부족, SELECT 권한도 함께 부여해야 한다. RLS가 본인 행으로 제한하므로 안전.
grant select on public.staff to authenticated;
drop policy if exists staff_self_read on public.staff;
create policy staff_self_read on public.staff
  for select to authenticated
  using (user_id = auth.uid());

-- 3) sessions: staff 전체 읽기 — 관리자 실시간 모니터링·통계용
--    (기존 anon 정책과 무관하게 additive)
drop policy if exists sessions_staff_read on public.sessions;
create policy sessions_staff_read on public.sessions
  for select to authenticated
  using (public.is_staff());

-- 4) 학생 전체 활성/비활성 — 해당 학번의 전 프로그램 행 일괄 변경 (admin 전용)
--    v2의 admin_set_student_active(토큰, 학번×프로그램 단위)와 별개 — v3는 Auth 게이트 + 학생 단위.
create or replace function public.admin_set_student_active_v3(p_hakbun text, p_active boolean)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  n int;
begin
  if not public.is_admin() then
    raise exception '관리자 권한이 필요합니다';
  end if;
  update public.students
     set "활성" = p_active, "수정일시" = now()
   where "학번" = p_hakbun;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'updated', n);
end
$$;
revoke execute on function public.admin_set_student_active_v3(text, boolean) from public;
revoke execute on function public.admin_set_student_active_v3(text, boolean) from anon;
grant execute on function public.admin_set_student_active_v3(text, boolean) to authenticated;

-- ============================================================
-- 확인 쿼리 (Run 후 실행해보면 적용 상태를 볼 수 있음)
-- select public.is_admin();                        -- SQL Editor에선 auth.uid()가 없어 false가 정상
-- select * from pg_policies where tablename in ('staff','sessions');
-- ============================================================
