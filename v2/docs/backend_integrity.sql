-- ══════════════════════════════════════════════════════════════════════════
--  출결 v2 — 출석 기록 무결성 서버측 강화 SQL  (Supabase / PostgreSQL)
--  작성: 코드 분석 배치4. 실제 스키마(2026-04) 기준.
--
--  ⚠️ 실행 전 필독
--   • 이 SQL은 '출석 기록의 권위를 클라이언트에서 서버로' 옮기는 변경이다.
--     트리거가 잘못 걸리면 정상 출석 insert까지 막힐 수 있으므로,
--     반드시 (1) 먼저 백업 (2) 수업이 없는 시간대에 (3) 아래 순서대로 하나씩 적용하며
--     각 단계 후 '테스트 세션 1건 + 출석 1건'으로 확인한다.
--   • 각 섹션 끝에 ROLLBACK(되돌리기)을 함께 뒀다.
--   • 핵심 예외: '사후여부=true'(교사 사후 등록)는 마감 세션에도 허용해야 하므로
--     트리거가 이를 통과시킨다. 이 예외를 빼면 사후 등록이 막힌다.
--
--  대상 컬럼(실제): attendance(세션id text, 학번 text, 날짜 date, 원래시각 time,
--     처리시각 timestamptz, 사후여부 bool, 상태 text, 생성일시 timestamptz),
--     sessions(세션id text, 날짜 date, 활성 bool, 만료시각 timestamptz, 종료시각 timestamptz)
-- ══════════════════════════════════════════════════════════════════════════


-- ──────────────────────────────────────────────────────────────────────────
-- [사전 점검] 아래를 먼저 실행해 '중복'이 이미 있는지 확인한다.
--   결과가 나오면 유니크 인덱스(섹션 1·4)가 실패하므로, 중복을 먼저 정리해야 한다.
-- ──────────────────────────────────────────────────────────────────────────
-- 같은 세션에 같은 학번이 2번 이상 출석된 경우(중복 체크인):
select 세션id, 학번, count(*)
from attendance
group by 세션id, 학번
having count(*) > 1
order by count(*) desc;

-- 같은 장소·날짜에 활성 세션이 2개 이상인 경우(중복 활성 세션):
select 장소, 날짜, count(*)
from sessions
where 활성 = true
group by 장소, 날짜
having count(*) > 1;


-- ══════════════════════════════════════════════════════════════════════════
-- 섹션 1 — 중복 출석 방지 (가장 안전·고가치, 먼저 적용)
--   같은 세션에서 같은 학번이 두 번 기록되는 것을 DB가 거부한다.
--   ※ 위 사전점검에서 중복이 있으면 먼저 정리 후 실행.
-- ══════════════════════════════════════════════════════════════════════════
create unique index if not exists uq_attendance_session_student
  on attendance (세션id, 학번);

-- ROLLBACK:
-- drop index if exists uq_attendance_session_student;


-- ══════════════════════════════════════════════════════════════════════════
-- 섹션 2 — 출석 날짜·시각의 서버 권위화 (기기 시계 의존 제거)
--   INSERT 시 attendance.날짜 를 세션의 날짜로 강제하고(자정 경계·폰 시각 오설정 방어),
--   처리시각/생성일시를 서버 시각(now())으로 채운다.
--   ※ 원래시각(학생 스캔 순간의 시각)은 그대로 둔다 — 학생 체감 기록.
-- ══════════════════════════════════════════════════════════════════════════
create or replace function trg_attendance_authoritative_time()
returns trigger
language plpgsql
as $$
declare
  v_session_date date;
begin
  -- 세션의 공식 날짜를 상속 (세션이 있으면 그 날짜로 덮어씀)
  select s.날짜 into v_session_date
  from sessions s
  where s.세션id = NEW.세션id
  limit 1;

  if v_session_date is not null then
    NEW.날짜 := v_session_date;   -- ★ 핵심: 날짜를 세션 날짜로 권위화(기기 시계 방어)
  end if;

  -- 생성일시가 비면 서버 시각으로 채움(안전)
  if NEW.생성일시 is null then
    NEW.생성일시 := now();
  end if;

  -- (선택) 처리시각도 서버 시각으로 강제하려면 아래 주석 해제.
  --   현재 클라이언트는 정상 등록 시 처리시각=null 로 두므로, 강제하면 null→now()로 바뀐다.
  --   동작 검토 후 켜는 것을 권장.
  -- NEW.처리시각 := now();

  return NEW;
end;
$$;

drop trigger if exists attendance_authoritative_time on attendance;
create trigger attendance_authoritative_time
  before insert on attendance
  for each row execute function trg_attendance_authoritative_time();

-- ROLLBACK:
-- drop trigger if exists attendance_authoritative_time on attendance;
-- drop function if exists trg_attendance_authoritative_time();


-- ══════════════════════════════════════════════════════════════════════════
-- 섹션 3 — 마감/만료 세션 출석 거부 (fail-closed 서버 권위)
--   클라이언트 검증이 실패해도 좀비 QR로 출석이 들어오지 않도록 DB가 거부한다.
--   ★ 예외: 사후여부=true (교사 사후 등록)는 마감 세션에도 허용한다.
--   ★ 예외: 세션 정보가 아예 없는 경우는 거부하지 않고 통과(레거시/특수 유입 보호) —
--          더 엄격히 하려면 아래 'else raise' 주석을 해제.
-- ══════════════════════════════════════════════════════════════════════════
create or replace function trg_attendance_reject_closed_session()
returns trigger
language plpgsql
as $$
declare
  s_active   boolean;
  s_expire   timestamptz;
  s_end      timestamptz;
  found_sess boolean := false;
begin
  -- 교사 사후 등록은 항상 허용
  if NEW.사후여부 is true then
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
      raise exception '마감되었거나 만료된 세션에는 출석할 수 없습니다 (세션 %).', NEW.세션id
        using errcode = 'check_violation';
    end if;
  -- else
  --   raise exception '존재하지 않는 세션입니다 (%).', NEW.세션id using errcode='check_violation';
  end if;

  return NEW;
end;
$$;

drop trigger if exists attendance_reject_closed_session on attendance;
create trigger attendance_reject_closed_session
  before insert on attendance
  for each row execute function trg_attendance_reject_closed_session();

-- ROLLBACK:
-- drop trigger if exists attendance_reject_closed_session on attendance;
-- drop function if exists trg_attendance_reject_closed_session();


-- ══════════════════════════════════════════════════════════════════════════
-- 섹션 4 — 중복 활성 세션 방지 (한 장소·날짜에 활성 세션 1개)
--   같은 장소·날짜에 활성 세션이 둘 생기면 QR·명단이 갈라지므로 부분 유니크로 막는다.
--   ※ 사전점검에서 중복 활성이 있으면 먼저 한쪽을 활성=false 로 정리 후 실행.
-- ══════════════════════════════════════════════════════════════════════════
create unique index if not exists uq_sessions_active_room_date
  on sessions (장소, 날짜)
  where 활성 = true;

-- ROLLBACK:
-- drop index if exists uq_sessions_active_room_date;


-- ══════════════════════════════════════════════════════════════════════════
-- 섹션 5 — (선택) 출결 상태 값 제약
--   상태 컬럼은 이미 존재하나 클라이언트가 항상 '출석'만 쓴다. 앞으로 지각/조퇴/결석 등을
--   쓸 계획이면 허용값을 고정해 오타·표류를 막는다. ※ 기존 데이터에 다른 값이 있으면 실패하므로
--   먼저 `select distinct 상태 from attendance;` 로 현재 값을 확인하고 목록을 맞춘다.
-- ══════════════════════════════════════════════════════════════════════════
-- select distinct 상태 from attendance;   -- 먼저 현재 값 확인
--
-- alter table attendance
--   add constraint chk_attendance_status
--   check (상태 in ('출석','지각','조퇴','결석','공결'));   -- 목록은 실제 운영에 맞춰 조정
--
-- ROLLBACK:
-- alter table attendance drop constraint if exists chk_attendance_status;


-- ══════════════════════════════════════════════════════════════════════════
-- 적용 순서 권장
--   1) 사전 점검 두 쿼리 → 중복 있으면 정리
--   2) 섹션 1 (중복 출석 유니크)         — 테스트 출석 1건
--   3) 섹션 2 (날짜·시각 서버 권위)      — 정상/자정경계 테스트
--   4) 섹션 3 (마감 세션 거부)           — 활성 세션 출석 OK / 마감 세션 출석 거부 / 사후 등록 OK 3가지 확인 ★
--   5) 섹션 4 (중복 활성 세션)           — 세션 2개 생성 시도해 막히는지
--   6) 섹션 5 (상태 제약, 선택)          — 상태 모델 도입 시
--
--   각 단계 후 문제가 생기면 해당 섹션 ROLLBACK 실행으로 즉시 원복.
-- ══════════════════════════════════════════════════════════════════════════
