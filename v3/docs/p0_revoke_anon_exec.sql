-- ═══════════════════════════════════════════════════════════════
--  v3 코어 RPC — anon EXECUTE 권한 회수 (2026-08-01)
--
--  배경: 대시보드에서 만든 v3 코어 함수 5종 + is_staff 가 anon에게도
--        EXECUTE 권한이 열려 있다. Postgres는 함수 생성 시 EXECUTE를
--        PUBLIC에 기본 부여하고 anon이 PUBLIC 멤버이기 때문 —
--        HANDOFF.md §7이 경고한 바로 그 함정이다.
--        (w3_crud_migration.sql로 만든 admin_*_v3 9종은 revoke가 들어
--         있어서 anon=false로 정상)
--
--  publishable(anon) 키는 HTML에 공개돼 있으므로, anon EXECUTE가 열려 있으면
--  누구나 PostgREST로 이 함수들을 직접 호출할 수 있다. 함수 본문이 내부에서
--  is_staff()/auth.uid()로 막고 있다면 실제 피해는 없지만, 막지 않는다면
--  세션 생성·퇴실코드 발급·강제 마감이 외부에서 가능하다.
--  → 어느 쪽이든 회수가 정답이다. v3는 전부 로그인 후 동작하므로
--    anon 호출자가 존재하지 않는다.
--
--  안전성 확인: v2 코드에서 이 함수들을 호출하는 곳 0건 (전수 검색 완료).
--              v3는 학생·교사·관리자 모두 authenticated 상태에서만 호출.
-- ═══════════════════════════════════════════════════════════════

-- ── 적용 (멱등 — 여러 번 실행해도 무해) ──
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in (
        'check_in', 'check_out',
        'create_v3_session', 'issue_exit_code', 'finalize_session',
        'is_staff'
      )
  loop
    -- ★ PUBLIC과 anon 둘 다 회수해야 한다. PUBLIC만 회수하면 anon에
    --   직접 부여된 권한이 남고, anon만 회수하면 PUBLIC 경유로 여전히 열린다.
    execute format('revoke execute on function %s from public', r.sig);
    execute format('revoke execute on function %s from anon', r.sig);
    execute format('grant  execute on function %s to authenticated', r.sig);
    raise notice '회수 완료: %', r.sig;
  end loop;
end $$;


-- ── 확인 — anon 열이 전부 false 여야 한다 ──
select p.proname                                            as "함수",
       has_function_privilege('anon',          p.oid, 'EXECUTE') as "anon",
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as "authenticated"
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and (p.proname like '%\_v3' or p.proname in
       ('is_staff', 'is_admin', 'check_in', 'check_out', 'issue_exit_code',
        'finalize_session', 'create_v3_session', 'staff_manual_attendance'))
order by 2 desc, 1;


-- ── 적용 후 반드시 라이브 스모크 ──
--  1) 학생: 로그인 → 입실 코드 입력 → 정상 입실
--  2) 교사: 로그인 → 세션 시작 → 퇴실 코드 발급 → 마감
--  둘 다 authenticated이므로 정상 동작해야 한다.
--  혹시 깨지면 즉시 롤백:
--     grant execute on function public.check_in(text) to anon;   -- 등 필요한 것만
