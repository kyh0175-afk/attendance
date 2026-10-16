-- 자습 참여 요일 조사 (2026-10-16)
-- 학생: 기간 안에 학번+이름 확인 → 프로그램별 참여·요일 제출 → 관리자 승인 시 students 반영
-- 기존 표는 바꾸지 않는다. 그만둠 = students.활성 false.
-- 되돌리기: 맨 아래 주석.

-- ── 명단 백업 + 그만둔 시각 열 (students 구조 변경 — 백업 먼저) ──────────
create table if not exists students_backup_2026_10_16 as table students;
alter table students_backup_2026_10_16 enable row level security;   -- 정책 없음 = anon 못 읽음
revoke all on students_backup_2026_10_16 from anon, authenticated;

-- 비활성일시 = 활성이 true→false 로 바뀐 시각. 다른 관리자 쓰기(장소·이름 수정, 이미 비활성인 행 재비활성화)가
-- 수정일시를 밀어도 흔들리지 않게 전이 순간만 기록한다. 분석이 이 날부터 대상에서 뺀다(index.html inactiveFromDate, D10)
alter table students add column if not exists 비활성일시 timestamptz;
create or replace function trg_students_inactive_at() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if new.활성 is distinct from old.활성 then
    if new.활성 then
      new.비활성일시 := null;
    elsif new.비활성일시 is not distinct from old.비활성일시 then   -- 호출자가 직접 정하지 않았으면 지금
      new.비활성일시 := now();
    end if;
  end if;
  return new;
end $$;
drop trigger if exists students_inactive_at on students;
create trigger students_inactive_at before update on students
  for each row execute function trg_students_inactive_at();
-- 이미 비활성인 행은 마지막 수정일로 채운다(최선값, 10/16 기준 5행 모두 4/22)
update students set 비활성일시 = 수정일시 where not 활성 and 비활성일시 is null;

-- ── 표 ─────────────────────────────────────────────────────────
create table if not exists survey_periods (
  id         bigint generated always as identity primary key,
  제목        text not null,
  시작        timestamptz not null default now(),
  마감        timestamptz not null,
  대상학년     int[] not null,
  대상프로그램  text[] not null,
  상태        text not null default 'open' check (상태 in ('open','closed')),
  생성일시     timestamptz not null default now()
);

create table if not exists survey_responses (
  id         bigint generated always as identity primary key,
  period_id  bigint not null references survey_periods(id),
  학번        text not null check (학번 ~ '^[0-9]{5}$'),
  이름        text not null,
  응답        jsonb not null,           -- {프로그램: [요일] | null(안 함)}
  제출때명단   jsonb not null,           -- {프로그램: {장소, 요일, 활성} | null}
  처리상태     text not null default '대기' check (처리상태 in ('대기','승인','거절','대체')),
  교사메모     text,
  처리내용     jsonb,                    -- 승인 때 실제로 바꾼 것
  제출일시     timestamptz not null default now(),
  처리일시     timestamptz
);
create unique index if not exists survey_responses_one_pending
  on survey_responses (period_id, 학번) where 처리상태 = '대기';
create index if not exists survey_responses_hakbun on survey_responses (학번, 제출일시);

alter table survey_periods   enable row level security;
alter table survey_responses enable row level security;
revoke all on survey_periods, survey_responses from anon, authenticated;
grant select on survey_periods, survey_responses to anon;   -- 관리자 화면 목록 읽기(정책이 관리자만 통과), 쓰기는 RPC만
create policy survey_periods_admin   on survey_periods   for all to anon
  using ((select cosmos_req_admin())) with check ((select cosmos_req_admin()));
create policy survey_responses_admin on survey_responses for all to anon
  using ((select cosmos_req_admin())) with check ((select cosmos_req_admin()));

-- ── 공통: 평일 프로그램 / 고정 요일 ─────────────────────────────
create or replace function survey_fixed_day(p_program text) returns text
language sql immutable set search_path = public, pg_temp as $$
  select case p_program when '토요일 독서시간' then '토' when '일요일 독서시간' then '일' end
$$;

-- 본인 확인(조사 전용): 명단에 그 학번 줄이 있으면(비활성 포함) 이름 대조 — 모두 그만둔 학생도 재참여 신고 가능(10/16 사용자 결정)
-- student_verify(활성 줄 필요)는 좌석 신청이 그대로 쓴다
create or replace function survey_verify(p_hakbun text, p_name text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select p_hakbun ~ '^[0-9]{5}$' and exists (
    select 1 from students
     where 학번 = p_hakbun
       and regexp_replace(이름, '\s', '', 'g') = regexp_replace(coalesce(p_name, ''), '\s', '', 'g'))
$$;

-- 지금 열린 기간(학생용 공개 정보만)
create or replace function survey_open() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((
    select jsonb_build_object('ok', true, 'id', id, '제목', 제목, '마감', 마감,
                              '대상학년', 대상학년, '대상프로그램', 대상프로그램)
      from survey_periods
     where 상태 = 'open' and now() between 시작 and 마감
     order by 마감 limit 1),
    jsonb_build_object('ok', false))
$$;

-- 학생의 지금 명단(대상 프로그램만)
create or replace function survey_snapshot(p_hakbun text, p_programs text[]) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_object_agg(p.prog, (
      select jsonb_build_object('장소', s.장소, '요일', coalesce(to_jsonb(s.출석요일), '[]'::jsonb), '활성', s.활성)
        from students s where s.학번 = p_hakbun and s.프로그램 = p.prog)), '{}'::jsonb)
    from unnest(p_programs) as p(prog)
$$;

-- 본인 확인 + 내 명단 + 내 대기 제출
create or replace function survey_me(p_hakbun text, p_name text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_open jsonb := survey_open(); v_pid bigint; v_progs text[]; v_pending survey_responses%rowtype;
begin
  if not (v_open->>'ok')::boolean then return jsonb_build_object('ok', false, 'code', 'closed'); end if;
  if not survey_verify(p_hakbun, p_name) then return jsonb_build_object('ok', false, 'code', 'verify'); end if;
  if not ((left(p_hakbun, 1))::int = any (array(select jsonb_array_elements_text(v_open->'대상학년')::int))) then
    return jsonb_build_object('ok', false, 'code', 'grade');
  end if;
  v_pid := (v_open->>'id')::bigint;
  v_progs := array(select jsonb_array_elements_text(v_open->'대상프로그램'));
  select * into v_pending from survey_responses where period_id = v_pid and 학번 = p_hakbun and 처리상태 = '대기';
  return jsonb_build_object('ok', true, 'period', v_open,
    -- 학생에게는 장소를 빼고 돌려준다(화면이 안 씀). 제출때명단에는 장소까지 남긴다
    '명단', (select coalesce(jsonb_object_agg(key, case when jsonb_typeof(value) = 'object' then value - '장소' else value end), '{}'::jsonb)
               from jsonb_each(survey_snapshot(p_hakbun, v_progs))),
    '대기', case when v_pending.id is null then null
                 else jsonb_build_object('응답', v_pending.응답, '제출일시', v_pending.제출일시) end,
    '최근처리', (select jsonb_build_object('처리상태', 처리상태, '처리일시', 처리일시)
                  from survey_responses where period_id = v_pid and 학번 = p_hakbun and 처리상태 in ('승인','거절')
                 order by 처리일시 desc limit 1));
end $$;

-- 제출: 규칙 검사 → 같은 학번 대기 건은 '대체'로, 새로 넣음
create or replace function survey_submit(p_hakbun text, p_name text, p_answer jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_open jsonb := survey_open(); v_pid bigint; v_progs text[]; v_prog text; v_days jsonb;
        v_clean jsonb := '{}'::jsonb; v_name text; v_id bigint; v_fixed text;
begin
  if not (v_open->>'ok')::boolean then return jsonb_build_object('ok', false, 'msg', '조사 기간 아님'); end if;
  if not survey_verify(p_hakbun, p_name) then return jsonb_build_object('ok', false, 'msg', '학번·이름 불일치'); end if;
  if not ((left(p_hakbun, 1))::int = any (array(select jsonb_array_elements_text(v_open->'대상학년')::int))) then
    return jsonb_build_object('ok', false, 'msg', '대상 학년 아님');
  end if;
  if p_answer is null or jsonb_typeof(p_answer) <> 'object' then return jsonb_build_object('ok', false, 'msg', '응답 형식 오류'); end if;
  v_pid := (v_open->>'id')::bigint;
  v_progs := array(select jsonb_array_elements_text(v_open->'대상프로그램'));

  if (select count(*) from survey_responses where 학번 = p_hakbun and 제출일시 > now() - interval '1 day') >= 20 then
    return jsonb_build_object('ok', false, 'msg', '제출 횟수 초과 · 내일 다시');
  end if;

  foreach v_prog in array v_progs loop
    if not (p_answer ? v_prog) then return jsonb_build_object('ok', false, 'msg', v_prog || ' 선택 없음'); end if;
    v_days := p_answer->v_prog;
    if v_days is null or jsonb_typeof(v_days) = 'null' then
      v_clean := v_clean || jsonb_build_object(v_prog, null);
      continue;
    end if;
    v_fixed := survey_fixed_day(v_prog);
    if v_fixed is not null then
      v_clean := v_clean || jsonb_build_object(v_prog, jsonb_build_array(v_fixed));
      continue;
    end if;
    if jsonb_typeof(v_days) <> 'array' or jsonb_array_length(v_days) = 0 then
      return jsonb_build_object('ok', false, 'msg', v_prog || ' 요일 선택 없음');
    end if;
    if exists (select 1 from jsonb_array_elements_text(v_days) d where d not in ('월','화','수','목','금')) then
      return jsonb_build_object('ok', false, 'msg', v_prog || ' 요일 오류');
    end if;
    -- 월~금 순서로 정리, 중복 제거
    v_clean := v_clean || jsonb_build_object(v_prog, (
      select jsonb_agg(d order by array_position(array['월','화','수','목','금'], d))
        from (select distinct jsonb_array_elements_text(v_days) d) x));
  end loop;

  select 이름 into v_name from students where 학번 = p_hakbun order by 활성 desc, 프로그램 limit 1;
  update survey_responses set 처리상태 = '대체', 처리일시 = now()
   where period_id = v_pid and 학번 = p_hakbun and 처리상태 = '대기';
  insert into survey_responses (period_id, 학번, 이름, 응답, 제출때명단)
  values (v_pid, p_hakbun, v_name, v_clean, survey_snapshot(p_hakbun, v_progs))
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, '응답', v_clean);
end $$;

-- 새 참여 행의 기본 장소(기존 장소 그대로 — 계획서 §4-1). 못 정하면 null
create or replace function survey_default_room(p_hakbun text, p_program text) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(
    (select 장소 from students where 학번 = p_hakbun and 프로그램 = p_program),
    case p_program
      when '방과후 독서시간' then (select 장소 from students where 학번 = p_hakbun and 프로그램 = '야간 독서시간')
      when '야간 독서시간'   then (select 장소 from students where 학번 = p_hakbun and 프로그램 = '방과후 독서시간')
      when '심야 독서시간'   then '리케이온'
      when '토요일 독서시간' then '리케이온'
      when '일요일 독서시간' then '리케이온'
    end)
$$;

-- ── 관리자 ─────────────────────────────────────────────────────
create or replace function admin_survey_period_save(p_token uuid, p_id bigint, p_title text,
  p_end timestamptz, p_grades int[], p_programs text[], p_state text default 'open') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id bigint;
begin
  perform assert_admin(p_token);
  if p_state not in ('open','closed') then return jsonb_build_object('ok', false, 'msg', '상태 오류'); end if;
  if exists (select 1 from unnest(p_programs) p where p not in
      ('방과후 독서시간','야간 독서시간','심야 독서시간','토요일 독서시간','일요일 독서시간')) then
    return jsonb_build_object('ok', false, 'msg', '프로그램 오류');
  end if;
  if p_id is null then
    insert into survey_periods (제목, 마감, 대상학년, 대상프로그램, 상태)
    values (p_title, p_end, p_grades, p_programs, p_state) returning id into v_id;
  else
    update survey_periods set 제목 = p_title, 마감 = p_end, 대상학년 = p_grades,
           대상프로그램 = p_programs, 상태 = p_state where id = p_id returning id into v_id;
    if v_id is null then return jsonb_build_object('ok', false, 'msg', '기간 없음'); end if;
  end if;
  -- 열린 기간은 하나만(survey_open 이 하나만 고른다) — 새로 연 기간 말고는 닫는다
  if p_state = 'open' then
    update survey_periods set 상태 = 'closed' where id <> v_id and 상태 = 'open';
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- 승인: p_rooms = {프로그램: 장소} — 기본 장소가 없는 새 참여에만 필요
create or replace function admin_survey_approve(p_token uuid, p_id bigint, p_rooms jsonb default '{}'::jsonb,
  p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r survey_responses%rowtype; v_prog text; v_days jsonb; v_row students%rowtype;
        v_room text; v_done jsonb := '[]'::jsonb; v_arr text[]; v_same boolean; v_hid bigint;
begin
  perform assert_admin(p_token);
  select * into r from survey_responses where id = p_id and 처리상태 = '대기' for update;
  if not found then return jsonb_build_object('ok', false, 'msg', '대기 중인 제출 없음'); end if;

  begin   -- 한 줄이라도 실패하면 이 제출의 반영을 모두 되돌린다
  for v_prog, v_days in select key, value from jsonb_each(r.응답) loop
    select * into v_row from students where 학번 = r.학번 and 프로그램 = v_prog;
    if jsonb_typeof(v_days) = 'null' then
      if v_row.학번 is not null and v_row.활성 then
        -- 그만둔 날 = 학생이 제출한 시각(승인이 늦어도 그 사이 세션을 결석으로 세지 않게)
        update students set 활성 = false, 비활성일시 = r.제출일시, 수정일시 = now() where 학번 = r.학번 and 프로그램 = v_prog;
        v_done := v_done || jsonb_build_object('프로그램', v_prog, '처리', '비활성',
          '이전요일', to_jsonb(v_row.출석요일), '이전활성', true);
      end if;
      continue;
    end if;
    v_arr := array(select jsonb_array_elements_text(v_days));
    if v_row.학번 is not null then
      -- 요일은 순서 없이 집합으로 비교(기존 ['목','화'] = 제출 ['화','목'])
      v_same := coalesce(v_row.출석요일, '{}') <@ v_arr and v_arr <@ coalesce(v_row.출석요일, '{}');
      -- 토·일은 요일이 고정이라 명단 요일 값(빈 배열 등)이 달라도 변경 아님
      if v_row.활성 and (v_same or survey_fixed_day(v_prog) is not null) then continue; end if;
      update students set 출석요일 = v_arr, 활성 = true, 수정일시 = now()
       where 학번 = r.학번 and 프로그램 = v_prog;
      -- 요일이 바뀌면 요일 변경 이력에도 승인 한 줄 → 분석(ensureDayChangeHist)이 과거를 이전 요일로 계산
      -- 이전 요일이 비어 있으면(=매일 대상) 빈 배열로 남겨 같은 뜻을 유지한다
      -- 넣은 뒤 승인으로 바꾼다: 요청 트리거(trg_request_fill_name)가 언젠가 insert 를 '대기'로 강제해도 승인 행이 남게
      if not v_same and survey_fixed_day(v_prog) is null then
        insert into day_change_requests (학번, 이름, 프로그램, 장소, 현재요일, 요청요일, 사유, 요청일시)
        values (r.학번, r.이름, v_prog, v_row.장소, coalesce(v_row.출석요일, '{}'::text[]), v_arr, '요일 조사', r.제출일시)
        returning id into v_hid;
        update day_change_requests set 처리상태 = '승인', 교사메모 = '요일 조사 #' || r.id, 처리일시 = now() where id = v_hid;
      end if;
      v_done := v_done || jsonb_build_object('프로그램', v_prog,
        '처리', case when v_row.활성 then '요일' else '재참여' end, '요일', v_days,
        '이전요일', to_jsonb(v_row.출석요일), '이전활성', v_row.활성);
    else
      v_room := coalesce(nullif(p_rooms->>v_prog, ''), survey_default_room(r.학번, v_prog));
      if v_room is null or v_room not in ('아우름','교과1실','해오름','리케이온') then
        raise exception '장소 지정 필요: %', v_prog;
      end if;
      insert into students (학번, 프로그램, 이름, 장소, 출석요일, 활성, 메모)
      values (r.학번, v_prog, r.이름, v_room, v_arr, true, '요일 조사');
      v_done := v_done || jsonb_build_object('프로그램', v_prog, '처리', '추가', '장소', v_room, '요일', v_days);
    end if;
  end loop;

  update survey_responses set 처리상태 = '승인', 교사메모 = p_note, 처리내용 = v_done, 처리일시 = now()
   where id = p_id;
  return jsonb_build_object('ok', true, '처리내용', v_done);
  exception when others then
    return jsonb_build_object('ok', false, 'msg', sqlerrm);
  end;
end $$;

create or replace function admin_survey_reject(p_token uuid, p_id bigint, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform assert_admin(p_token);
  update survey_responses set 처리상태 = '거절', 교사메모 = p_note, 처리일시 = now()
   where id = p_id and 처리상태 = '대기';
  if not found then return jsonb_build_object('ok', false, 'msg', '대기 중인 제출 없음'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- ── 실행 권한 ───────────────────────────────────────────────────
revoke all on function survey_verify(text, text), survey_fixed_day(text), survey_open(), survey_snapshot(text, text[]),
  survey_me(text, text), survey_submit(text, text, jsonb), survey_default_room(text, text),
  admin_survey_period_save(uuid, bigint, text, timestamptz, int[], text[], text),
  admin_survey_approve(uuid, bigint, jsonb, text), admin_survey_reject(uuid, bigint, text)
  from public, anon, authenticated;
grant execute on function survey_open(), survey_me(text, text), survey_submit(text, text, jsonb),
  admin_survey_period_save(uuid, bigint, text, timestamptz, int[], text[], text),
  admin_survey_approve(uuid, bigint, jsonb, text), admin_survey_reject(uuid, bigint, text)
  to anon;

-- ── 첫 기간 (사용자 결정 10/16: 1·2학년, 5개 프로그램, 10/31 23:59 KST) ──
insert into survey_periods (제목, 마감, 대상학년, 대상프로그램)
select '2학기 자습 참여 요일 조사', '2026-10-31 23:59:59+09', array[1,2],
       array['방과후 독서시간','야간 독서시간','심야 독서시간','토요일 독서시간','일요일 독서시간']
 where not exists (select 1 from survey_periods);

-- ── 되돌리기 ───────────────────────────────────────────────────
-- drop function if exists admin_survey_reject(uuid,bigint,text), admin_survey_approve(uuid,bigint,jsonb,text),
--   admin_survey_period_save(uuid,bigint,text,timestamptz,int[],text[],text), survey_default_room(text,text),
--   survey_submit(text,text,jsonb), survey_me(text,text), survey_snapshot(text,text[]), survey_open(), survey_fixed_day(text),
--   survey_verify(text,text);
-- delete from day_change_requests where 사유 = '요일 조사';   -- 승인 때 넣은 요일 이력
-- drop trigger if exists students_inactive_at on students; drop function if exists trg_students_inactive_at();
-- alter table students drop column if exists 비활성일시;   -- (index.html 은 없으면 수정일시로 돌아감)
-- 명단 전체 되돌리기가 필요하면 students_backup_2026_10_16 에서 복원
-- drop table if exists survey_responses, survey_periods;
-- (승인으로 바뀐 students 행은 survey_responses.처리내용 기록을 보고 되돌린다 — 표를 지우기 전에 내보낼 것)
