do $t$
declare out text := '';
begin
  set local role anon;
  insert into day_change_requests (학번,프로그램,현재요일,요청요일,사유,처리상태,교사메모) values ('99999','방과후 독서시간','{}','{월}','x','승인','m');
  insert into correction_requests (학번,프로그램,장소,대상날짜,현재상태,요청상태,사유,처리상태) values ('99999','방과후 독서시간','아우름','2026-10-16','결석','출석','x','승인');
  reset role;
  out := 'dcr_pending=' || (select (처리상태 = '대기' and 교사메모 is null)::text from day_change_requests where 학번='99999')
      || ' cr_pending=' || (select (처리상태 = '대기')::text from correction_requests where 학번='99999');
  raise exception 'RESULT %', out;
end $t$;
