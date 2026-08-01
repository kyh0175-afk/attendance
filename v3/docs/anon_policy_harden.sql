-- ═══════════════════════════════════════════════════════════════
--  anon RLS 정책 축소 (2026-08-01)
--
--  ★ 배경 — 지금 상태
--    anon_all_attendance / anon_all_sessions / anon_all_students
--      = FOR ALL · USING (true) · role {anon}
--    publishable(anon) 키는 HTML에 공개돼 있으므로, 누구나 REST로
--    이 테이블들을 읽고(쓰기는 GRANT가 허용하는 범위에서) 조작할 수 있다.
--
--  ★ 핵심 문제 — v3 설계 무력화
--    sessions 테이블에 v3의 `입실코드`·`퇴실코드`·`퇴실코드만료`가 들어 있고
--    anon SELECT가 USING(true)라, 교실에 오지 않아도 두 코드를 모두 읽을 수 있다.
--    → 입실도 퇴실도 원격에서 가능 = "찍튀 방지"라는 v3의 전제가 무너진다.
--
--  ★ 이 스크립트가 하는 일
--    v2가 실제로 쓰는 경로만 남기고 나머지를 RLS 레벨에서 닫는다.
--    v2 세션은 `입실코드`가 null(v3 전용 컬럼)이므로, 그 조건으로
--    v2용 행과 v3용 행을 정확히 가를 수 있다.
--
--  ★ v2 실사용 조사 결과 (v2/index.html 전수 grep)
--      sessions      SELECT 7 · UPDATE 4 · INSERT 1   → 전부 유지 (v2 행 한정)
--      attendance    SELECT 7 · INSERT 2 · DELETE 2   → SELECT·INSERT 유지
--                    UPDATE 0회  ← 한 번도 안 쓴다. 닫아도 무해
--      students      SELECT 4                          → SELECT만 유지
--      teacher_logs  INSERT 1 · SELECT 1               → 손대지 않음
--
--  ⚠️ 읽기(명단·출석 전체 조회)는 v2 구조상 지금 닫을 수 없다.
--     v2 은퇴(9월 초 예정) 후 별도로 회수할 것.
-- ═══════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────
-- 0. 실행 전 — 현재 정책 백업 (결과를 어딘가 복사해 두면 안심)
-- ───────────────────────────────────────────────────────────────
select tablename, policyname, cmd, roles::text, qual, with_check
from pg_policies
where schemaname = 'public' and tablename in ('sessions', 'attendance', 'students')
order by tablename, policyname;


-- ───────────────────────────────────────────────────────────────
-- 1. 적용 — 한 트랜잭션으로 묶어 중간 실패 시 원상복구
-- ───────────────────────────────────────────────────────────────
begin;

-- ── sessions : v3 세션(입실코드 있음)을 anon에게서 완전히 감춘다 ──
--    v2가 만드는 세션은 입실코드가 null이라 그대로 보이고 수정도 된다.
--    v3 세션은 조회·수정 모두 차단 → 코드 유출 경로가 사라진다.
--    (v3는 authenticated + is_staff() 정책으로 읽고, check_in/check_out은
--     SECURITY DEFINER라 RLS를 우회하므로 영향 없음)
drop policy if exists anon_all_sessions on public.sessions;

create policy anon_read_sessions on public.sessions
  for select to anon
  using ("입실코드" is null);

create policy anon_insert_sessions on public.sessions
  for insert to anon
  with check ("입실코드" is null);

create policy anon_update_sessions on public.sessions
  for update to anon
  using ("입실코드" is null)
  with check ("입실코드" is null);

-- ── attendance : FOR ALL → SELECT + INSERT ──
--    UPDATE 정책을 만들지 않으므로 RLS가 anon의 수정을 막는다(GRANT와 무관).
--    지금은 anon이 출석 기록의 상태·퇴실시각·이름을 마음대로 고칠 수 있다.
drop policy if exists anon_all_attendance on public.attendance;

create policy anon_read_attendance on public.attendance
  for select to anon
  using (true);

create policy anon_insert_attendance on public.attendance
  for insert to anon
  with check (true);

-- GRANT도 같이 정리 (RLS로 이미 막히지만 이중 방어)
revoke update on public.attendance from anon;

-- ── students : FOR ALL → SELECT ──
--    쓰기 GRANT는 이미 닫혀 있지만, 정책이 ALL이면 GRANT가 실수로 열릴 때
--    RLS가 그대로 통과시킨다. 정책 자체를 읽기로 좁힌다.
drop policy if exists anon_all_students on public.students;

create policy anon_read_students on public.students
  for select to anon
  using (true);

commit;
-- rollback;   -- ← 중간에 이상하면 commit 대신 이 줄


-- ───────────────────────────────────────────────────────────────
-- 2. 검증
-- ───────────────────────────────────────────────────────────────

-- 2-a. 정책 목록 — anon에 ALL이 하나도 없어야 한다
select tablename as "테이블", policyname as "정책", cmd as "명령",
       roles::text as "역할", coalesce(qual, '-') as "USING"
from pg_policies
where schemaname = 'public'
  and tablename in ('sessions', 'attendance', 'students')
  and roles::text like '%anon%'
order by tablename, cmd;

-- 2-b. anon이 볼 수 있는 세션 — v3 세션(입실코드 있음)이 0건이어야 한다
select count(*) filter (where "입실코드" is null)     as "anon이 보는 v2 세션",
       count(*) filter (where "입실코드" is not null) as "anon에게 가려진 v3 세션"
from public.sessions;


-- ───────────────────────────────────────────────────────────────
-- 3. 적용 후 v2 스모크 (병행 운영 중이므로 반드시)
-- ───────────────────────────────────────────────────────────────
--  1) v2 교사 화면에서 세션 시작 → QR 뜨는지
--  2) v2 학생 QR 출석 1건 → 명단에 잡히는지
--  3) v2 교사 화면 마감 → 세션이 닫히는지
--  4) v2 'check' 화면(내 출석 확인) → 기록이 보이는지
--  5) v3 교사·학생 흐름 1회 → 그대로인지
--
--  하나라도 깨지면 아래로 즉시 원복:
--
--    begin;
--      drop policy if exists anon_read_sessions   on public.sessions;
--      drop policy if exists anon_insert_sessions on public.sessions;
--      drop policy if exists anon_update_sessions on public.sessions;
--      drop policy if exists anon_read_attendance   on public.attendance;
--      drop policy if exists anon_insert_attendance on public.attendance;
--      drop policy if exists anon_read_students     on public.students;
--      create policy anon_all_sessions   on public.sessions   for all to anon using (true);
--      create policy anon_all_attendance on public.attendance for all to anon using (true);
--      create policy anon_all_students   on public.students   for all to anon using (true);
--      grant update on public.attendance to anon;
--    commit;


-- ───────────────────────────────────────────────────────────────
-- 4. v2 은퇴 후 (9월 초 예정) — 그때 실행할 것, 지금은 아님
-- ───────────────────────────────────────────────────────────────
--    begin;
--      drop policy if exists anon_read_sessions     on public.sessions;
--      drop policy if exists anon_insert_sessions   on public.sessions;
--      drop policy if exists anon_update_sessions   on public.sessions;
--      drop policy if exists anon_read_attendance   on public.attendance;
--      drop policy if exists anon_insert_attendance on public.attendance;
--      drop policy if exists anon_read_students     on public.students;
--      revoke all on public.sessions, public.attendance, public.students from anon;
--    commit;
--    → 이 시점에 DESIGN.md가 v3 채택 근거로 든 "v2에서 못 닫은 PII 읽기"가 종결된다.
