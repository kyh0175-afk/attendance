
-- 시험(롤백 전용): 끝에서 예외를 던져 모든 변경을 되돌린다
do $t$
declare tok uuid := gen_random_uuid(); r jsonb; out text := ''; pid bigint; n int; s record;
  procedure_ok boolean;
begin
  insert into admin_sessions (token, expires_at) values (tok, now() + interval '10 minutes');
  -- 시험 기간: 마감이 제일 빠르게 → survey_open 이 이것을 고른다
  insert into survey_periods (제목, 마감, 대상학년, 대상프로그램)
  values ('시험', now() + interval '1 hour', array[9],
          array['방과후 독서시간','야간 독서시간','심야 독서시간','토요일 독서시간','일요일 독서시간'])
  returning id into pid;
  insert into students (학번, 프로그램, 이름, 장소, 출석요일, 활성) values
    ('99901','방과후 독서시간','시험가','교과1실', array['화'], true),
    ('99901','심야 독서시간','시험가','리케이온', array['월','수'], true),
    ('99902','심야 독서시간','시험나','리케이온', array['금'], true),
    ('99903','방과후 독서시간','시험다','아우름', null, true),
    ('99904','야간 독서시간','시험라','해오름', array['화'], false);   -- 모두 그만둔 학생

  r := survey_open();                         out := out || E'\n01 open ' || (r->>'ok') || ' ' || (r->>'제목');
  r := survey_me('99901','틀림');              out := out || E'\n02 me-wrong ' || r::text;
  r := survey_me('10101','아무개');            out := out || E'\n03 me-other ' || r::text;
  r := survey_me('99901','시험 가');           out := out || E'\n04 me ' || (r->>'ok') || ' ' || (r->'명단')::text;
  r := survey_submit('99901','시험가','{"방과후 독서시간":["목","화"]}');
                                              out := out || E'\n05 missing ' || r::text;
  r := survey_submit('99901','시험가','{"방과후 독서시간":[],"야간 독서시간":null,"심야 독서시간":null,"토요일 독서시간":null,"일요일 독서시간":null}');
                                              out := out || E'\n06 empty ' || r::text;
  r := survey_submit('99901','시험가','{"방과후 독서시간":["토"],"야간 독서시간":null,"심야 독서시간":null,"토요일 독서시간":null,"일요일 독서시간":null}');
                                              out := out || E'\n07 badday ' || r::text;
  r := survey_submit('99901','시험가','{"방과후 독서시간":["화"],"야간 독서시간":null,"심야 독서시간":null,"토요일 독서시간":null,"일요일 독서시간":null}');
  r := survey_submit('99901','시험가','{"방과후 독서시간":["목","화","화"],"야간 독서시간":["월"],"심야 독서시간":null,"토요일 독서시간":["아무거나"],"일요일 독서시간":null}');
                                              out := out || E'\n08 ok ' || r::text;
  select count(*) into n from survey_responses where 학번='99901' and 처리상태='대기';
  out := out || E'\n09 pending=' || n || ' replaced=' || (select count(*) from survey_responses where 학번='99901' and 처리상태='대체');
  r := survey_me('99901','시험가');            out := out || E'\n10 me-pending ' || (r->'대기'->'응답')::text;
  r := admin_survey_approve(tok, (r->'대기'->>'id')::bigint);   -- id 없음 → 실패해야
                                              out := out || E'\n11 approve-noid ' || r::text;
  r := admin_survey_approve(tok, (select id from survey_responses where 학번='99901' and 처리상태='대기'));
                                              out := out || E'\n12 approve ' || r::text;
  for s in select 프로그램, 장소, 출석요일, 활성, 메모 from students where 학번='99901' order by 프로그램 loop
    out := out || E'\n13   ' || s.프로그램 || ' ' || s.장소 || ' ' || coalesce(array_to_string(s.출석요일, ','), '-') || ' ' || s.활성 || ' ' || coalesce(s.메모,'');
  end loop;
  for s in select 프로그램, 현재요일, 요청요일, 처리상태, 사유 from day_change_requests where 학번='99901' loop
    out := out || E'\n13h  hist ' || s.프로그램 || ' ' || array_to_string(s.현재요일, ',') || '→' || array_to_string(s.요청요일, ',') || ' ' || s.처리상태 || ' ' || s.사유;
  end loop;
  out := out || E'\n13p  처리내용 이전요일 ' || coalesce((select 처리내용::text from survey_responses where 학번='99901' and 처리상태='승인'), 'null');
  -- 짝 행 없는 새 방과후 → 장소 지정 필요
  r := survey_submit('99902','시험나','{"방과후 독서시간":["월"],"야간 독서시간":null,"심야 독서시간":["금"],"토요일 독서시간":null,"일요일 독서시간":null}');
  r := admin_survey_approve(tok, (r->>'id')::bigint);
                                              out := out || E'\n14 approve-noroom ' || r::text;
  out := out || E'\n15 rows-after-fail ' || (select count(*) from students where 학번='99902');
  r := admin_survey_approve(tok, (select id from survey_responses where 학번='99902' and 처리상태='대기'), '{"방과후 독서시간":"해오름"}');
                                              out := out || E'\n16 approve-room ' || r::text;
  -- 요일 빔 행 학생 + 거절
  r := survey_me('99903','시험다');            out := out || E'\n17 me-nulldays ' || (r->'명단'->'방과후 독서시간')::text;
  r := survey_submit('99903','시험다','{"방과후 독서시간":["수"],"야간 독서시간":null,"심야 독서시간":null,"토요일 독서시간":null,"일요일 독서시간":null}');
  r := admin_survey_reject(tok, (r->>'id')::bigint, '시험');  out := out || E'\n18 reject ' || r::text;
  r := survey_me('99903','시험다');            out := out || E'\n19 me-after-reject ' || coalesce((r->'최근처리')::text,'null');
  -- 모두 그만둔 학생: 조사 본인 확인 통과(좌석용 student_verify 는 그대로 막힘), 재참여 승인
  r := survey_me('99904','시험라');            out := out || E'\n19b me-all-inactive ' || (r->>'ok') || ' student_verify=' || student_verify('99904','시험라');
  r := survey_submit('99904','시험라','{"방과후 독서시간":null,"야간 독서시간":["화","수"],"심야 독서시간":null,"토요일 독서시간":null,"일요일 독서시간":null}');
  r := admin_survey_approve(tok, (r->>'id')::bigint);
  out := out || E'\n19c rejoin ' || (r->>'ok') || ' ' || (select 장소 || ' ' || array_to_string(출석요일, ',') || ' ' || 활성 from students where 학번='99904' and 프로그램='야간 독서시간')
             || ' hist=' || (select count(*) from day_change_requests where 학번='99904' and 처리상태='승인');
  begin
    r := admin_survey_approve(gen_random_uuid(), 1);
    out := out || E'\n20 approve-badtoken FAIL(통과됨) ' || r::text;
  exception when insufficient_privilege then
    out := out || E'\n20 approve-badtoken 거부 OK';
  end;
  begin
    r := admin_survey_period_save(gen_random_uuid(), null, 'x', now(), array[1], array['방과후 독서시간']);
    out := out || E'\n21 period-badtoken FAIL';
  exception when insufficient_privilege then
    out := out || E'\n21 period-badtoken 거부 OK';
  end;
  r := admin_survey_period_save(tok, null, '시험2', now() + interval '2 hour', array[9], array['방과후 독서시간'], 'open');
  out := out || E'\n21b one-open open=' || (select count(*) from survey_periods where 상태='open')
             || ' picked=' || ((survey_open()->>'id')::bigint = (r->>'id')::bigint);
  -- 비활성일시: 승인 그만둠 = 제출 시각 / 이미 비활성인 행을 다시 비활성화·장소 수정해도 안 바뀜 / 재활성화 = null
  out := out || E'\n23a quit-at=submit ' || ((select 비활성일시 from students where 학번='99901' and 프로그램='심야 독서시간')
                = (select 제출일시 from survey_responses where 학번='99901' and 처리상태='승인'));
  perform pg_sleep(0.01);
  update students set 활성 = false, 장소 = '해오름', 수정일시 = now() where 학번='99901' and 프로그램='심야 독서시간';
  out := out || E'\n23b re-deactivate-keeps ' || ((select 비활성일시 from students where 학번='99901' and 프로그램='심야 독서시간')
                = (select 제출일시 from survey_responses where 학번='99901' and 처리상태='승인'));
  update students set 활성 = true where 학번='99901' and 프로그램='심야 독서시간';
  out := out || E'\n23c reactivate-null ' || ((select 비활성일시 from students where 학번='99901' and 프로그램='심야 독서시간') is null);
  update students set 활성 = false where 학번='99901' and 프로그램='심야 독서시간';
  out := out || E'\n23d plain-deactivate-now ' || ((select 비활성일시 from students where 학번='99901' and 프로그램='심야 독서시간') is not null);
  out := out || E'\n23e backup-rows ' || ((select count(*) from students_backup_2026_10_16) = (select count(*) from students where 학번 !~ '^999'))
             || ' anon-read-backup=' || has_table_privilege('anon','students_backup_2026_10_16','select');
  out := out || E'\n22 anon-exec survey_snapshot=' || has_function_privilege('anon','survey_snapshot(text,text[])','execute')
             || ' survey_default_room=' || has_function_privilege('anon','survey_default_room(text,text)','execute')
             || ' survey_me=' || has_function_privilege('anon','survey_me(text,text)','execute')
             || ' tbl-insert=' || has_table_privilege('anon','survey_responses','insert');
  raise exception 'RESULT%', out;
exception when others then
  if sqlerrm like 'RESULT%' then raise exception '%', sqlerrm; end if;
  raise exception 'RESULT%  !! %', out, sqlerrm;
end $t$;
