-- 자율 출석을 명단에 올리기 (2026-10-16 사용자 지시)
-- 대상: 2026-08-19 이후 출석했는데 그 프로그램에 활성 행이 없는 (학번×프로그램) — 10/16 미리보기 71쌍(새 행 70·재활성 1)
-- 장소 = 실제로 가장 많이 출석한 장소, 요일 = 실제로 온 요일(토·일 프로그램은 그 요일), 이름 = 그 학생의 다른 행
-- 메모 '자율 출석 등록'. 학번 목록은 공개 레포라 적지 않는다(백업 표 students_backup_2026_10_16b 와 비교하면 나옴).

create table students_backup_2026_10_16b as table students;
alter table students_backup_2026_10_16b enable row level security;
revoke all on students_backup_2026_10_16b from anon, authenticated;

with att as (select * from attendance where 날짜 >= '2026-08-19'),
pairs as (select a.학번, a.프로그램 from att a
           where not exists (select 1 from students s where s.학번 = a.학번 and s.프로그램 = a.프로그램 and s.활성)
           group by 1, 2),
room as (select distinct on (a.학번, a.프로그램) a.학번, a.프로그램, a.장소 from att a join pairs p using (학번, 프로그램)
          group by a.학번, a.프로그램, a.장소 order by a.학번, a.프로그램, count(*) desc, a.장소),
days as (select a.학번, a.프로그램,
          array(select x from unnest(array_agg(distinct (array['일','월','화','수','목','금','토'])[extract(dow from a.날짜)::int + 1])) x
                order by array_position(array['월','화','수','목','금','토','일'], x)) d
          from att a join pairs p using (학번, 프로그램) group by 1, 2),
nm as (select distinct on (학번) 학번, 이름 from students order by 학번, 활성 desc)
insert into students (학번, 프로그램, 이름, 장소, 출석요일, 활성, 메모, 수정일시)
select p.학번, p.프로그램, nm.이름, r.장소, d.d, true, '자율 출석 등록', now()
  from pairs p join room r using (학번, 프로그램) join days d using (학번, 프로그램) join nm using (학번)
on conflict (학번, 프로그램) do update
  set 활성 = true, 장소 = excluded.장소, 출석요일 = excluded.출석요일,
      메모 = coalesce(students.메모 || ' · ', '') || '자율 출석 등록', 수정일시 = now();

-- ── 되돌리기 ─────────────────────────────────────────────────────
-- delete from students where 메모 = '자율 출석 등록'
--   and (학번, 프로그램) not in (select 학번, 프로그램 from students_backup_2026_10_16b);
-- update students st set 활성 = b.활성, 장소 = b.장소, 출석요일 = b.출석요일, 메모 = b.메모, 수정일시 = now()
--   from students_backup_2026_10_16b b
--  where st.학번 = b.학번 and st.프로그램 = b.프로그램 and st.메모 like '%자율 출석 등록';
