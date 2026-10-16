-- 2학기 미출석 명단 정리 (2026-10-16 사용자 지시)
-- 기준 A: 마지막 출석이 2026-05-01 이전인 학생의 활성 행 전부 (39행·33명 — 모두 B에 포함)
-- 기준 B: (학번×프로그램) 활성 행 중 그 프로그램에 2026-08-19(2학기 첫 세션) 이후 출석 0회 (10/16 자율 등록 뒤 재조회 228행·165명, 이 중 104명은 전 프로그램 비활성)
-- 처리: 활성 = false. 비활성일시는 트리거가 지금으로 기록 → 분석은 오늘부터 대상 아님, 그 전 2학기 결석은 그대로 셈.
-- 학번 목록은 공개 레포라 여기 적지 않는다(로컬 _리뷰\비활성화대상_20261016.md, 백업 표 students_backup_2026_10_16c).

create table students_backup_2026_10_16c as table students;
alter table students_backup_2026_10_16c enable row level security;
revoke all on students_backup_2026_10_16c from anon, authenticated;

with s as (select 학번, 프로그램 from students where 활성),
last_any as (select 학번, max(날짜) d from attendance group by 학번),
a as (select s.학번, s.프로그램 from s join last_any l using (학번) where l.d < '2026-05-01'),
b as (select s.학번, s.프로그램 from s
       where not exists (select 1 from attendance t where t.학번 = s.학번 and t.프로그램 = s.프로그램 and t.날짜 >= '2026-08-19')),
u as (select 학번, 프로그램 from a union select 학번, 프로그램 from b)
update students st set 활성 = false, 수정일시 = now()
  from u where st.학번 = u.학번 and st.프로그램 = u.프로그램 and st.활성;

-- ── 되돌리기(이번에 비활성화한 행만 다시 활성) ─────────────────────
-- update students st set 활성 = true, 수정일시 = now()
--   from students_backup_2026_10_16c b
--  where st.학번 = b.학번 and st.프로그램 = b.프로그램 and b.활성 and not st.활성;
