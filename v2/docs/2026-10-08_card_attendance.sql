-- ═══════════════════════════════════════════════════════════════
--  RF 회원카드 출석 (2026-10-08) — 1단계: DB와 서버 함수
--  배경: 폰 없이 카드로 출석. 리더 = 13.56MHz USB 키보드식, 카드 UID만 읽는다.
--  단말: 키오스크 PC(해오름·리케이온), 출석용 전자칠판(아우름·교과1실)
--  원칙: 카드 표·단말 표·기록 표는 anon/authenticated 직접 접근 없음. 전부 아래 RPC로만.
--        원래 UID는 저장하지 않고 sha256(서버 비밀값 + UID)만 저장한다(비밀값은 DB 안에서 생성, 레포에 없음).
--  적용: 2026-10-08 Supabase migration v2_card_attendance_20261008 + v2_card_rooms_search_path_20261008
--        (적용 전 라이브 DB에서 되돌리는 시험 2회, 적용 뒤 QR식 삽입·마감 차단 재확인)
--  기존 QR 출석·화면 동작은 바꾸지 않는다. 시간 규칙은 QR과 같다(같은 날 화면 커밋: QR 30분, 연장 없음).
--  사용자 결정(10/8): 시작 전에 찍으면 거절(시작 뒤 출석) / 다른 쌍 방 학생도 출석하되 관리자 확인용 표시 /
--                    오프라인이면 단말에 보관했다 재전송(단말 시계 대신 '찍은 뒤 지난 ms'를 받아 서버 시각으로 계산).
-- ═══════════════════════════════════════════════════════════════

-- 0) 서버 비밀값 (1행). 마이그레이션 때 DB 안에서 무작위 생성.
create table if not exists public.card_secret (
  id     int primary key default 1 check (id = 1),
  pepper text not null
);
insert into public.card_secret(id, pepper)
values (1, encode(extensions.gen_random_bytes(32), 'hex'))
on conflict (id) do nothing;

-- 1) 카드: UID 해시 ↔ 학번
create table if not exists public.cards (
  uid_hash  text primary key,
  학번      text not null check (학번 ~ '^\d{5}$'),
  상태      text not null default '사용' check (상태 in ('사용', '분실')),
  등록일시  timestamptz not null default now(),
  수정일시  timestamptz not null default now()
);
-- 학생 한 명당 '사용' 카드는 하나
create unique index if not exists cards_one_active_per_student on public.cards(학번) where 상태 = '사용';

-- 2) 단말: 토큰 해시 ↔ 장소쌍
create table if not exists public.card_devices (
  id          bigint generated always as identity primary key,
  token_hash  text not null unique,
  이름        text not null check (char_length(이름) between 1 and 30),
  장소쌍      text not null check (장소쌍 in ('아우름', '리케이온')),
  활성        boolean not null default true,
  생성일시    timestamptz not null default now(),
  마지막접속  timestamptz
);

-- 3) 찍은 기록(진단·제한용). 결과: 출석·이미출석·미등록카드·분실카드·세션없음·학생없음·기한지남·제한
--    비고(관리자 확인용): '다른 방'(그 프로그램을 다른 쌍 방에 등록한 학생) · '늦게 도착'(오프라인 보관분이 마감 뒤 도착)
create table if not exists public.card_taps (
  id        bigint generated always as identity primary key,
  device_id bigint references public.card_devices(id),
  uid_hash  text not null,
  찍은시각  timestamptz not null,
  받은시각  timestamptz not null default now(),
  결과      text not null,
  학번      text,
  세션id    text,
  비고      text
);
create index if not exists card_taps_device_time on public.card_taps(device_id, 받은시각 desc);
create index if not exists card_taps_time on public.card_taps(받은시각 desc);

alter table public.card_secret  enable row level security;
alter table public.cards        enable row level security;
alter table public.card_devices enable row level security;
alter table public.card_taps    enable row level security;
revoke all on public.card_secret, public.cards, public.card_devices, public.card_taps from anon, authenticated;

-- ── 내부 도우미 ──────────────────────────────────────────────
create or replace function public._card_norm_uid(p_uid text)
 returns text language plpgsql immutable
 set search_path to 'public', 'pg_temp'
as $function$
declare u text := upper(regexp_replace(coalesce(p_uid, ''), '\s', '', 'g'));
begin
  if u !~ '^[0-9A-F]{4,24}$' then
    raise exception '카드 번호 형식이 아닙니다' using errcode = 'check_violation';
  end if;
  return u;
end$function$;

create or replace function public._card_hash(p_uid text)
 returns text language sql stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
  select encode(extensions.digest((select pepper from card_secret where id = 1) || ':' || public._card_norm_uid(p_uid), 'sha256'), 'hex')
$function$;

create or replace function public._card_rooms(p_pair text)
 returns text[] language sql immutable
 set search_path to 'public', 'pg_temp'
as $function$
  select case p_pair when '아우름' then array['아우름', '교과1실']
                     when '리케이온' then array['리케이온', '해오름'] end
$function$;

create or replace function public._card_device(p_device_token text)
 returns public.card_devices language plpgsql security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare d card_devices;
begin
  select * into d from card_devices
   where token_hash = encode(extensions.digest(coalesce(p_device_token, ''), 'sha256'), 'hex') and 활성;
  if d.id is null then
    raise exception '등록되지 않은 단말입니다' using errcode = 'insufficient_privilege';
  end if;
  update card_devices set 마지막접속 = now() where id = d.id;
  return d;
end$function$;

-- ── 단말용 ──────────────────────────────────────────────────
-- 카드 출석. p_age_ms = 단말이 카드를 읽은 뒤 지난 시간(ms). 바로 보내면 0, 오프라인 보관분은 그만큼.
-- 단말 시계를 믿지 않고 서버 시각에서 빼서 '찍은 시각'을 정한다.
create or replace function public.card_check_in(p_device_token text, p_uid text, p_age_ms bigint default 0)
 returns jsonb language plpgsql security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  d      card_devices;
  h      text;
  age    bigint := greatest(coalesce(p_age_ms, 0), 0);
  queued boolean := coalesce(p_age_ms, 0) > 5000;   -- 5초 넘게 지난 기록 = 오프라인 보관분
  t      timestamptz;
  c      cards;
  s      sessions;
  ls     sessions;
  nm     text;
  rm     text;
  res    text;
  note   text;
  n      int;
begin
  d := _card_device(p_device_token);
  h := _card_hash(p_uid);
  t := now() - make_interval(secs => age / 1000.0);

  -- 보관분은 12시간까지만
  if t < now() - interval '12 hours' then
    insert into card_taps(device_id, uid_hash, 찍은시각, 결과) values (d.id, h, t, '기한지남');
    return jsonb_build_object('ok', false, '결과', '기한지남');
  end if;

  -- 단말당 1분 60회 넘으면 거절(잘못된 입력 반복 방지)
  select count(*) into n from card_taps where device_id = d.id and 받은시각 > now() - interval '1 minute';
  if n >= 60 then
    insert into card_taps(device_id, uid_hash, 찍은시각, 결과) values (d.id, h, t, '제한');
    return jsonb_build_object('ok', false, '결과', '제한');
  end if;

  select * into c from cards where uid_hash = h;
  if c.uid_hash is null then res := '미등록카드';
  elsif c.상태 <> '사용' then res := '분실카드';
  end if;
  if res is not null then
    insert into card_taps(device_id, uid_hash, 찍은시각, 결과, 학번) values (d.id, h, t, res, c.학번);
    return jsonb_build_object('ok', false, '결과', res);
  end if;

  -- 찍은 시각에 그 장소쌍에서 열려 있던 출석 (QR과 같은 창: 시작 ~ 만료/마감)
  select * into s from sessions
   where 장소 = any(_card_rooms(d.장소쌍))
     and 시작시각 <= t
     and t < least(만료시각, coalesce(종료시각, 'infinity'::timestamptz))
     and (queued or 활성)   -- 바로 찍은 카드는 마감 안 된 출석에만
   order by 시작시각 desc, id asc
   limit 1;

  -- 이름: 그 프로그램 등록 행 → 아무 등록 행
  select st.이름 into nm from students st
   where st.학번 = c.학번
   order by (st.프로그램 = s.프로그램) desc nulls last, st.활성 desc
   limit 1;
  if nm is null then
    insert into card_taps(device_id, uid_hash, 찍은시각, 결과, 학번) values (d.id, h, t, '학생없음', c.학번);
    return jsonb_build_object('ok', false, '결과', '학생없음', '학번', c.학번);
  end if;

  -- 열린 출석 없음(시작 전·마감 뒤) → 오늘 이 쌍에서 가장 최근에 마감된 출석을 함께 알려 준다
  if s.id is null then
    select * into ls from sessions
     where 장소 = any(_card_rooms(d.장소쌍))
       and 날짜 = (t at time zone 'Asia/Seoul')::date
       and 시작시각 <= t
     order by 시작시각 desc, id asc
     limit 1;
    insert into card_taps(device_id, uid_hash, 찍은시각, 결과, 학번) values (d.id, h, t, '세션없음', c.학번);
    return jsonb_build_object('ok', false, '결과', '세션없음', '학번', c.학번, '이름', nm,
      '최근마감', case when ls.id is null then null else jsonb_build_object(
        '프로그램', ls.프로그램,
        '마감시각', to_char(least(ls.만료시각, coalesce(ls.종료시각, 'infinity'::timestamptz)) at time zone 'Asia/Seoul', 'HH24:MI')) end);
  end if;

  -- 장소: 학생이 그 프로그램에 등록한 방이 이 쌍 안이면 그 방, 아니면 세션 첫 행의 방
  select st.장소 into rm from students st
   where st.학번 = c.학번 and st.프로그램 = s.프로그램 and st.장소 = any(_card_rooms(d.장소쌍))
   limit 1;
  if rm is null then
    rm := s.장소;
    -- 그 프로그램을 다른 쌍 방에 등록한 학생 → 출석은 받고 관리자 확인용으로 표시
    if exists (select 1 from students st where st.학번 = c.학번 and st.프로그램 = s.프로그램) then
      note := '다른 방';
    end if;
  end if;

  -- 보관분은 그 사이 출석이 마감됐을 수 있다 → 마감 차단 트리거에 이 한 줄만 통과시킨다(위에서 찍은 시각에 열려 있었음을 확인함)
  if queued and (not s.활성 or s.종료시각 is not null or s.만료시각 <= now()) then
    perform set_config('cosmos.card_queued', 'on', true);
    note := concat_ws(', ', note, '늦게 도착');
  end if;
  insert into attendance(세션id, 학번, 이름, 날짜, 원래시각, 처리시각, 사후여부, 프로그램, 장소, 교사, 상태, 메모)
  values (s.세션id, c.학번, nm, s.날짜, (t at time zone 'Asia/Seoul')::time(0), null, false,
          s.프로그램, rm, nullif(s.교사, ''), '출석', '카드')
  on conflict (학번, 세션id) do nothing;
  get diagnostics n = row_count;
  perform set_config('cosmos.card_queued', 'off', true);
  res := case when n > 0 then '출석' else '이미출석' end;
  if n = 0 then note := null; end if;   -- 이미 출석이면 표시할 것 없음

  insert into card_taps(device_id, uid_hash, 찍은시각, 결과, 학번, 세션id, 비고)
  values (d.id, h, t, res, c.학번, s.세션id, note);
  return jsonb_build_object('ok', true, '결과', res, '학번', c.학번, '이름', nm, '비고', note,
                            '프로그램', s.프로그램, '시각', to_char(t at time zone 'Asia/Seoul', 'HH24:MI'));
end$function$;

-- 마감 차단 트리거: 기존 규칙 그대로 + card_check_in이 표시한 '늦게 보낸 카드' 한 줄만 예외
-- (cosmos.card_queued는 card_check_in 안에서만 켜고 끈다. 일반 요청은 이 값을 설정할 길이 없다)
create or replace function public.trg_attendance_reject_closed_session()
 returns trigger
 language plpgsql
 set search_path to 'public', 'pg_temp'
as $function$
declare
  s_active   boolean;
  s_expire   timestamptz;
  s_end      timestamptz;
  found_sess boolean := false;
begin
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
      if NEW.메모 = '카드' and current_setting('cosmos.card_queued', true) = 'on' then
        return NEW;
      end if;
      raise exception '마감되었거나 만료된 세션에는 출석할 수 없습니다 (세션 %).', NEW.세션id
        using errcode = 'check_violation';
    end if;
  end if;

  return NEW;
end;
$function$;

-- 단말 화면 상단: 지금 열린 출석과 오늘 카드 출석 수
create or replace function public.card_device_status(p_device_token text)
 returns jsonb language plpgsql security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare d card_devices; s sessions; n int;
begin
  d := _card_device(p_device_token);
  select * into s from sessions
   where 장소 = any(_card_rooms(d.장소쌍)) and 활성 and 만료시각 > now()
   order by 시작시각 desc, id asc limit 1;
  select count(*) into n from card_taps
   where device_id = d.id and 결과 = '출석'
     and 받은시각 >= date_trunc('day', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul';
  return jsonb_build_object(
    '단말', d.이름, '장소쌍', d.장소쌍, '오늘카드출석', n,
    '세션', case when s.id is null then null else jsonb_build_object(
      '세션id', s.세션id, '프로그램', s.프로그램, '교사', s.교사, '만료시각', s.만료시각,
      '출석수', (select count(*) from attendance a where a.세션id = s.세션id)) end);
end$function$;

-- ── 관리자용 (assert_admin) ──────────────────────────────────
-- 카드 등록. 같은 학생의 옛 카드는 '분실'로 돌린다. 다른 학생에게 묶인 카드면 p_force 없이는 거절.
create or replace function public.admin_card_enroll(p_token uuid, p_uid text, p_학번 text, p_force boolean default false)
 returns jsonb language plpgsql security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare h text; c cards; nm text; replaced int := 0;
begin
  perform assert_admin(p_token);
  h := _card_hash(p_uid);
  select 이름 into nm from students where 학번 = p_학번 order by 활성 desc limit 1;
  if nm is null then
    return jsonb_build_object('ok', false, 'msg', '학생 명단에 없는 학번입니다: ' || coalesce(p_학번, ''));
  end if;
  select * into c from cards where uid_hash = h;
  if c.uid_hash is not null and c.학번 <> p_학번 and c.상태 = '사용' and not p_force then
    return jsonb_build_object('ok', false, 'msg', '이미 다른 학생(' || c.학번 || ')에게 등록된 카드입니다', '다른학번', c.학번);
  end if;
  update cards set 상태 = '분실', 수정일시 = now()
   where 학번 = p_학번 and 상태 = '사용' and uid_hash <> h;
  get diagnostics replaced = row_count;
  insert into cards(uid_hash, 학번, 상태) values (h, p_학번, '사용')
  on conflict (uid_hash) do update set 학번 = excluded.학번, 상태 = '사용', 수정일시 = now();
  return jsonb_build_object('ok', true, '학번', p_학번, '이름', nm, '옛카드분실', replaced);
end$function$;

-- 카드 상태 바꾸기(분실 ↔ 사용) — 학번 기준(그 학생의 가장 최근 카드)
create or replace function public.admin_card_set_status(p_token uuid, p_학번 text, p_상태 text)
 returns jsonb language plpgsql security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare h text;
begin
  perform assert_admin(p_token);
  if p_상태 not in ('사용', '분실') then
    return jsonb_build_object('ok', false, 'msg', '상태 값 오류');
  end if;
  select uid_hash into h from cards where 학번 = p_학번 order by 수정일시 desc limit 1;
  if h is null then return jsonb_build_object('ok', false, 'msg', '등록된 카드가 없습니다'); end if;
  if p_상태 = '사용' then
    update cards set 상태 = '분실', 수정일시 = now() where 학번 = p_학번 and 상태 = '사용' and uid_hash <> h;
  end if;
  update cards set 상태 = p_상태, 수정일시 = now() where uid_hash = h;
  return jsonb_build_object('ok', true);
end$function$;

-- 카드 목록(학생별 최신 카드 + 마지막 사용)
create or replace function public.admin_card_list(p_token uuid)
 returns jsonb language plpgsql security definer
 set search_path to 'public', 'pg_temp'
as $function$
begin
  perform assert_admin(p_token);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      '학번', c.학번, '상태', c.상태, '등록일시', c.등록일시, '카드끝', right(c.uid_hash, 4),
      '마지막사용', (select max(t.받은시각) from card_taps t where t.uid_hash = c.uid_hash and t.결과 in ('출석', '이미출석'))
    ) order by c.학번, c.수정일시 desc)
    from cards c), '[]'::jsonb);
end$function$;

-- 최근 찍은 기록(진단용). p_flagged_only = 비고('다른 방'·'늦게 도착')·미등록카드만
create or replace function public.admin_card_taps(p_token uuid, p_limit int default 100, p_flagged_only boolean default false)
 returns jsonb language plpgsql security definer
 set search_path to 'public', 'pg_temp'
as $function$
begin
  perform assert_admin(p_token);
  return coalesce((
    select jsonb_agg(x order by x.받은시각 desc) from (
      select t.받은시각, t.찍은시각, t.결과, t.비고, t.학번, t.세션id, d.이름 as 단말, right(t.uid_hash, 4) as 카드끝,
             (select st.이름 from students st where st.학번 = t.학번 limit 1) as 이름
        from card_taps t left join card_devices d on d.id = t.device_id
       where not coalesce(p_flagged_only, false) or t.비고 is not null or t.결과 = '미등록카드'
       order by t.받은시각 desc limit least(greatest(coalesce(p_limit, 100), 1), 500)) x), '[]'::jsonb);
end$function$;

-- 단말 발급: 토큰 원문은 이 응답에서 한 번만 보인다(저장은 해시만)
create or replace function public.admin_card_device_issue(p_token uuid, p_이름 text, p_장소쌍 text)
 returns jsonb language plpgsql security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare raw text := encode(extensions.gen_random_bytes(24), 'hex'); new_id bigint;
begin
  perform assert_admin(p_token);
  insert into card_devices(token_hash, 이름, 장소쌍)
  values (encode(extensions.digest(raw, 'sha256'), 'hex'), btrim(p_이름), p_장소쌍)
  returning id into new_id;
  return jsonb_build_object('ok', true, 'id', new_id, 'token', raw);
end$function$;

create or replace function public.admin_card_device_list(p_token uuid)
 returns jsonb language plpgsql security definer
 set search_path to 'public', 'pg_temp'
as $function$
begin
  perform assert_admin(p_token);
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id', id, '이름', 이름, '장소쌍', 장소쌍, '활성', 활성, '생성일시', 생성일시, '마지막접속', 마지막접속) order by id)
    from card_devices), '[]'::jsonb);
end$function$;

create or replace function public.admin_card_device_revoke(p_token uuid, p_id bigint)
 returns jsonb language plpgsql security definer
 set search_path to 'public', 'pg_temp'
as $function$
begin
  perform assert_admin(p_token);
  update card_devices set 활성 = false where id = p_id;
  return jsonb_build_object('ok', found);
end$function$;

-- 실행 권한: 도우미는 막고, 공개 RPC만 anon에 연다(내부에서 단말 토큰·관리자 토큰 검사)
revoke all on function public._card_norm_uid(text), public._card_hash(text), public._card_rooms(text),
  public._card_device(text) from public, anon, authenticated;
revoke all on function public.card_check_in(text, text, bigint), public.card_device_status(text),
  public.admin_card_enroll(uuid, text, text, boolean), public.admin_card_set_status(uuid, text, text),
  public.admin_card_list(uuid), public.admin_card_taps(uuid, int, boolean),
  public.admin_card_device_issue(uuid, text, text), public.admin_card_device_list(uuid),
  public.admin_card_device_revoke(uuid, bigint) from public;
grant execute on function public.card_check_in(text, text, bigint), public.card_device_status(text),
  public.admin_card_enroll(uuid, text, text, boolean), public.admin_card_set_status(uuid, text, text),
  public.admin_card_list(uuid), public.admin_card_taps(uuid, int, boolean),
  public.admin_card_device_issue(uuid, text, text), public.admin_card_device_list(uuid),
  public.admin_card_device_revoke(uuid, bigint) to anon, authenticated;
