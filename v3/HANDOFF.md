# 코스모스 출석 v3 — 작업 인계 문서 (2026-07-21)

> 다른 컴퓨터/새 세션에서 이어서 작업하기 위한 자립형 문서.
> 설계 근거·전체 그림은 같은 폴더 **`DESIGN.md`** 참고. 이 문서는 "지금까지 뭘 했고 / 다음에 뭘 / 어떻게 이어가나".

---

## 0. 한눈에 — 지금 어디까지 왔나

| 트랙 | 상태 |
|---|---|
| 보안(v2 라이브 하드닝) | ✅ 완결 (DB 마이그 다수 + 클라 배포, 아래 §7) |
| v3 설계 확정 | ✅ `DESIGN.md` (결정 A~G 확정) |
| v3 W1 (학생 로그인·대시보드) | ✅ + 리디자인(독서등 톤) |
| v3 W2 (코드 입퇴실: 학생+교사) | ✅ E2E 실동작 확인 |
| 학생 계정 벌크 생성 | ✅ 2026-07-22 실행 완료 — **292명** 전원 생성·검증 (아래 주의 참고) |
| W3 (관리자 화면·통계) | ✅ **완결** (2026-07-22) — 4탭(오늘/기록/통계/명단)+설정. 마이그 2종 적용, CRUD RPC 라이브 13/13, 적대리뷰 2라운드 반영 |
| 도메인 연결 | ✅ **완결** (2026-07-22) — `cosmos.yubongsystem.com` HTTPS 라이브. Cloudflare CNAME(DNS only) + repo CNAME 파일 |
| W4 (파일럿) | ⬜ **다음 작업** — 방학 자습 실전 테스트(~8/16) |

**★ 라이브 URL(커스텀 도메인)**: 학생 `https://cosmos.yubongsystem.com/v3/` · 교사 `…/v3/teacher.html` · 관리자 `…/v3/admin.html` · v2 `…/v2/`. (경로가 `/attendance/v3/`→`/v3/`로 바뀜 — 커스텀 도메인이 레포 루트를 서빙. 기존 github.io 주소·QR은 자동 리다이렉트.)

**바로 다음 할 일**:
1. **[보류·설계됨] 퇴실 코드 자동 발급** — 세션 시작 시 프로그램 종료 시각을 자동으로 채워(교사 수정 가능) 그 시각에 앱이 자동으로 `issueExitCode` 호출+마감 버튼 노출. 종료시각: 방과후 18:20·야간 21:30·심야 23:00·일요일 17:30·**토요일 12:30/17:30(시작 시각 13시 기준 오전·오후 추정)**. 전제=교사 단말이 세션 화면 켜져 있어야 함(클라 타이머). 기기 꺼도 되게 하려면 서버 스케줄러(Edge Function+cron)=별도 작업. 타이밍(정각 vs N분 전)은 사용자 확정 대기. 수동 '발급' 버튼은 폴백으로 유지.
2. **W4 파일럿** — 세션 시작→학생 입·퇴실→마감→관리자 기록·통계 확인.
- 잔여 소소한 것 = supabase-js CDN 벤더링 백로그. 폰트 통일(단일 IBM Plex)은 사용자 확인 없이 유지 중 — 세리프 워드마크 복원 원하면 커밋 d641a2d 참조.

**교사 화면 개선(2026-07-22, 사용자 피드백 2라운드)**: ① 세션 정보(프로그램·장소·교사)를 상단 바로 이동 ② 출석 현황 학년 토글(전체/1/2/3, 학번 첫자리) ③ **수동 출석**(오프라인·코드 불가 대비, `staff_manual_attendance` RPC=is_staff 게이트·메모'수동입실'·명단 '수동' 배지) ④ 마감 버튼은 퇴실코드 발급 후에만 노출(실수 마감 방지)+발급 후 '재발급'으로 ⑤ 나가기 버튼 상단 이동·문구 명확화. **+3라운드**: 입실 코드를 '나가기' 오른쪽에 큰 숫자로 배치(codecard 제거, 헤더 행 sesshdr, clamp 44~84px, 퇴실코드는 발급 시 다크 카드로 별도 표시)·폰트 통일(위 디자인 시스템). 라이브 스모크 5/5. 헤드리스 스크린샷·오버플로 측정(scrollW==clientW)으로 레이아웃 검증. 교사 PIN=001052(must_change_pin 없음). 60310 서혜인→30610 정정+고아 계정 삭제 완료.

**W3 라운드2(2026-07-22 오후) — v2 대비 기능 보충**: 사용자가 고른 범위대로 ① **기록 탭**(날짜별 세션 브라우즈·sibling 병합·사후 출석 추가·상태정정(출석/조퇴/퇴실미확인/결석)·출석/세션 삭제) ② **명단 CRUD**([+학생추가]·[관리] 모달=프로그램별 수정·활성토글·삭제, 엑셀 일괄 업로드/양식 — **v2 양식 100% 호환**) ③ **출석률(등록별)** — v2 매트릭스 간소화판(대상일=세션 열린 날×출석요일×첫 출석 이후, 낮은순 정렬, 행 펼치면 날짜 도트). 좌석·코스모스 모듈은 DESIGN 확정대로 v2 유지. 서버 = `docs/w3_crud_migration.sql`(RPC 8종, is_admin 게이트). **저장형 XSS 수정**(student.js/teacher.js 렌더에 esc — 엑셀로 악성 이름 적재 시 교사/학생 화면 발화 차단). 적대 리뷰 2라운드(Opus find·Fable verify) 확정건 전부 반영, CRUD 라이브 스모크 13/13 PASS.

> **★ 학생 수 정정**: 이전 판의 "582명"은 `students` **행 수**(581)를 잘못 센 것. 이 테이블은 (학번×프로그램) 등록 행이라 한 학생이 최대 4행 — 실제 고유 학생은 **292명**(활성 576행). 스크립트가 학번 기준 dedup하므로 계정도 292개가 정답.
> **★ 발견된 명단 오타**: `60310 서혜인`(토요일, 4/30 수기 등록)은 `30610 서혜인`(심야)과 동일 학생의 학번 오타로 추정(고교에 6학년 없음). 계정은 둘 다 생성됨 — 확인 후 students 행 학번 정정 + `60310@st...` 계정 삭제 권장.

---

## 1. 프로젝트 개요

- **무엇**: 유봉여고 "코스모스 독서시간" 자습 출석. v2(단일 QR 입실)의 **찍튀(입실 후 무단이탈)** 문제를 **입실+퇴실 2포인트 코드**로 해결하는 v3.
- **스택**: 프론트=바닐라 JS(빌드 없음, ES 모듈), 백엔드=Supabase(Postgres+Auth+RLS), 호스팅=GitHub Pages.
- **레포**: `github.com/kyh0175-afk/attendance` (main 브랜치). v2=`/v2/`, v3=`/v3/`.
- **v3 라이브 URL(도메인 연결 전)**: `https://kyh0175-afk.github.io/attendance/v3/` (학생), `.../v3/teacher.html` (교사)
- **최종 도메인(파일럿 전 연결)**: `cosmos.yubongsystem.com` (사자님 보유) → GitHub Pages CNAME 예정. ★도메인 확정 후 오픈(PWA 설치·로그인 상태가 도메인 종속).

## 2. 새 컴퓨터 세팅 (이어가기 전 1회)

1. **레포 클론**: `git clone https://github.com/kyh0175-afk/attendance.git` (또는 Google Drive 동기화 폴더 사용). push 권한 = 사자님 계정.
2. **Supabase MCP 연결** (Claude Code에서 DB 직접 조회/변경하려면):
   - Personal access token 발급: supabase.com/dashboard/account/tokens
   - 환경변수 `SUPABASE_ACCESS_TOKEN`에 setx로 설정(채팅에 붙여넣지 말 것) → Claude Code 재시작
   - 등록(Windows 함정 주의 — `--` 파싱/MSYS 경로변환 때문에 아래가 정답):
     ```
     MSYS_NO_PATHCONV=1 claude mcp add-json supabase '{"type":"stdio","command":"cmd","args":["/c","npx","-y","@supabase/mcp-server-supabase@latest","--project-ref=rxsmmwqekrtbstcjbagj"]}' -s user
     ```
     (읽기전용으로 하려면 args에 `"--read-only"` 추가. 쓰기 필요하면 빼기.)
   - Supabase 프로젝트 ref: **`rxsmmwqekrtbstcjbagj`**
3. **service_role 키**(계정 생성 스크립트용): 대시보드 → Settings → API → `service_role`. **커밋 금지, 환경변수로만.** (`tools/README.md`)

## 3. 인증(Auth) 구조 — 반드시 이해하고 시작

- **학생**: Supabase Auth. 가상 이메일 `{학번}@st.yubongsystem.com` + PIN(비밀번호). 이메일 발송/확인 없음(`email_confirm=true`로 미리 확정). 자가가입 없음 — 관리자가 계정 생성.
- **교사**: 공용 계정 `teacher@staff.yubongsystem.com` + 교사 PIN. `staff` 테이블(user_id→role)에 등록돼야 `is_staff()`가 true. teacher.html은 이 이메일로 로그인(config `STAFF_EMAIL`), 담당교사 이름은 세션 시작 시 입력.
- **관리자**: (W3) 미정 — v2 토큰 체계 재사용 또는 staff role='admin'.
- **★★ 페이지별 auth 저장키 분리 (핵심 함정)**: 학생 index.html = `cosmos_v3_auth`, 교사 teacher.html = `cosmos_v3_staff`. **같은 브라우저에서 뒤에 로그인한 쪽이 앞 세션을 덮어쓰는 문제** 때문에 반드시 분리. `sb.js`의 `setAuthStorageKey()`를 페이지 모듈 최상단에서 호출. **admin.html도 새 키(`cosmos_v3_admin`) 쓸 것.**
- RLS: 학생은 본인 학번 행만(attendance/students/correction/daychange SELECT), 교사(staff)는 전체. `is_staff()` = SECURITY DEFINER.

## 4. 이미 만들어진 것 (파일)

```
v3/
  index.html            학생 PWA (로그인·PIN변경·대시보드·입실/퇴실 시트)
  teacher.html          교사 콘솔 (로그인·세션시작·명단·퇴실코드·마감)
  admin.html            관리자 (오늘 현황·통계·명단·설정/진단 — W3, 2026-07-22)
  assets/js/
    config.js           SUPABASE_URL/KEY(공개 anon), EMAIL_DOMAIN, STAFF_EMAIL, ADMIN_EMAIL, PROGRAMS, ROOMS
    sb.js               Supabase 클라이언트 + auth + DAL + setAuthStorageKey() + 관리자 DAL(fetchAllPaged 등)
    student.js          학생 페이지 컨트롤러
    teacher.js          교사 페이지 컨트롤러
    admin.js            관리자 페이지 컨트롤러 (저장키 cosmos_v3_admin)
  docs/w3_migration.sql W3 서버측 마이그레이션 (is_admin·staff self read+GRANT·sessions staff read·활성토글 RPC)
  sw.js                 서비스워커(앱셸 캐시, 네트워크우선)
  manifest.webmanifest  PWA
  icon-*.png, icon.svg  아이콘(v2 복사)
  DESIGN.md             설계서(권위본)
  HANDOFF.md            이 문서
  tools/                로컬 도구 3종: create-accounts.mjs(학생 벌크) · create-admin.mjs(관리자 생성/PIN재발급) · reset-pin.mjs(학생 PIN 초기화)
```

**디자인 시스템**(계승할 것): 따뜻한 크림/브라운(v2 유지) + "독서등" 다크 히어로 카드 + 램프골드 액센트(#c7994f). 모션=카운트업·스프링 뷰전환·촉각버튼·햅틱·reduced-motion. **폰트=IBM Plex Sans KR 단일**(2026-07-22 사용자 요청으로 통일 — 구 Cormorant Garamond 워드마크 제거, "Cosmos"는 굵은 이탤릭+골드로 워드마크 유지. 명령/코드 블록만 monospace). ★광원(글로우) 효과는 사자님이 뺐음 — 넣지 말 것.

## 5. DB 스키마 (v3 추가분, v2와 연속)

- `attendance` + `퇴실시각 timestamptz`, `퇴실방식 text`('코드'|'키오스크'|'교사수동'|'조퇴'). 상태값: '출석' | '퇴실미확인' | '조퇴'.
- `sessions` + `입실코드 text`, `퇴실코드 text`, `퇴실코드만료 timestamptz`.
- `staff`(user_id uuid PK, role 'teacher'|'admin', 이름) — RLS on, definer 함수만 접근.

**v3 RPC** (전부 SECURITY DEFINER):
- `check_in(p_code)` / `check_out(p_code)` — 학생(authenticated). auth.email→학번. 입실 idempotent, 퇴실은 만료·본인입실 검증.
- `issue_exit_code(p_session_id)` — staff. 4자리 랜덤, 10분 만료.
- `finalize_session(p_session_id)` — staff. 미퇴실 '퇴실미확인' 마킹 + 세션 비활성.
- `create_v3_session(p_program,p_room,p_teacher)` — staff. 같은 방 활성세션 비활성 후 생성, 입실코드 자동.
- `is_staff()` — auth.uid가 staff에 있나.
- 학생 쓰기 RPC(보안트랙): admin_*·self_register_student 등 (§7).

## 6. 다음 작업 순서 (권장)

1. ~~**학생 계정 생성**~~ ✅ 2026-07-22 완료 (292명, 실패 0 — §0 정정·오타 메모 참고).
2. **W3 관리자 화면** ✅ 구현 완료 (2026-07-22) — 남은 것과 구현 내역:
   - **남은 것**: ⓐ `docs/w3_migration.sql` 적용 — 적용 전에도 화면은 동작(오늘/통계/명단 읽기·CSV). 적용해야 열리는 것 = 활성/비활성 토글·진단 role 표시·(퇴실 지표의 세션 기반 정밀 판별) ⓑ 관리자 첫 로그인(임시 PIN → 새 PIN 6~12자리) ⓒ 4탭 라이브 E2E ⓓ 커밋·push.
   - **인증 결정(확정)**: v2 토큰 재사용 대신 **Supabase Auth 통합** — `admin@staff.yubongsystem.com`(staff role='admin', tools/create-admin.mjs로 생성됨). gateOk = 이메일+is_staff, is_admin() 배포 후엔 role 판정 추가. 관리자 PIN 6~12자리 강제.
   - **화면**: 오늘(활성 세션 카드·같은 세션id sibling 행 dedup·재실=학번 고유 계수·15초 폴링) / 통계(기간·프로그램 필터, 퇴실 지표는 세션+퇴실흔적 이중 판별, 반복 미퇴실자, 일별 차트, CSV — 수식 인젝션 방어·퇴실시각 KST 통일) / 명단(학생 단위, 활성 토글은 RPC, PIN 초기화는 로컬 도구 안내 모달) / 설정(시스템 진단·PIN 변경·도구 명령).
   - **적대 리뷰**: 38에이전트(Find=Opus 4렌즈, Verify=Fable 2인 교차) — 확정 7건 전건 수정(CSV 수식 인젝션·sibling 이중 집계·CSV/화면 퇴실시각 TZ·세션 비가독 시 통계 오표시·관리자 PIN 4자리·재실 중복 계수), 기각 7건(예: "sessions에 id 없음" 주장은 라이브 DB로 반증 — **id 컬럼 실존**).
   - (선택) v2 관리자 기능 이식 — v2 admin은 그대로 살아있으니 급하지 않음. **백로그**: supabase-js CDN 버전 고정/벤더링(SRI — admin만이 아니라 오리진 전체 결정 필요).
3. **도메인 연결**: `cosmos.yubongsystem.com` → GitHub Pages 커스텀 도메인(CNAME). 오픈 전 확정.
4. **W4 파일럿**: 방학 자습(현재 세션 0)에서 실전 테스트.
5. **개학 후 측정 모드 2주**: 퇴실 체크 운영하되 제재·통보 없이 통계만 → 실태 보고 → 룰 확정.

**스코프 제외(재론 금지)**: 학부모 알림(영구 제외), GPS/네이티브앱(기각), 좌석모듈(v2 유지), 랜덤 현장점검(기각). 근거 `DESIGN.md`.

## 7. 보안 트랙 요약 (v2 라이브 — 건드리지 말 것)

7/21에 v2의 라이브 취약점을 대거 수리함(이미 배포·검증 완료). **되돌리지 말 것:**
- 관리자 비번: 평문 노출 → `verify_admin_password`/`admin_login`(토큰) RPC로. anon 비번읽기 차단.
- 관리자 쓰기(삭제/명단수정/요청승인/코스모스/좌석): 전부 `admin_*` 토큰 RPC 뒤로 + anon 직접쓰기 회수. 학생 자가등록·요청제출·출석INSERT는 anon 유지.
- RLS-off 3테이블(teacher_logs/sessions_audit/students_backup) 잠금. 좀비QR 차단 트리거(마감세션 출석 거부).
- ★함정: 함수 EXECUTE는 PUBLIC 기본부여+anon 멤버 → 회수는 `from public` AND `from anon,authenticated` 둘 다.
- **잔여**: PII '읽기'(명단·출석 anon SELECT)는 v2 구조상 열림 — 이건 v3(Auth+RLS)가 해결. v2 자체는 그대로 운영.

## 8. 함정·교훈 (실수 방지)

- **auth.users 직접 INSERT 하는 SECURITY DEFINER 함수 = Claude Code 분류기가 차단**(라이브 auth 쓰기 민감). 계정 생성은 **Auth Admin API**(로컬 스크립트/Edge Function)로. → `tools/`.
- **페이지별 auth 저장키 분리** 필수(§3). admin.html도.
- **GitHub Pages JS 캐시(~10분)** + 서비스워커 → 수정 후 테스트 시 **하드 새로고침** 또는 시크릿/다른 브라우저. 교사·학생 동시 테스트는 **다른 브라우저**로.
- **한글 컬럼/식별자**: Postgres 함수 파라미터는 ascii(p_hakbun 등)로, 본문은 위치참조($n)로 원본 호출(한글 인용 회피). 컬럼명은 한글 그대로(학번/세션id/퇴실시각…).
- `원래시각`은 `time`타입 — 텍스트 넣지 말고 `(now() at time zone 'Asia/Seoul')::time`.
- 커밋 메시지 영문, deploy는 그냥 `git push`(GitHub Pages 자동). Google Drive 폴더면 `.git` 동기화 주의.
- Supabase MCP 쓰기 필요 시 read-only 빼고 등록. 쓰기 상시개방은 지양(작업 후 되돌리기 고려).

## 9. 테스트 계정·상태 메모

- 학생 테스트 계정: `99999@st.yubongsystem.com` (수동 생성, `must_change_pin` 없음) 잔존. **실 학생 292계정은 2026-07-22 생성 완료** — 초기 PIN=학번, `must_change_pin=true`, email_confirmed. 검증: Auth 총 294 = 학생 293(292+테스트) + 교사 1.
- **관리자 계정**: `admin@staff.yubongsystem.com` 2026-07-22 생성 + staff(role=admin) 등록 완료(tools/create-admin.mjs). 임시 PIN 발급 상태 — 첫 로그인·PIN 변경 대기. 분실 시 create-admin.mjs 재실행.
- **Supabase MCP**: 2026-07-22 user 스코프 등록 완료. 연결엔 `SUPABASE_ACCESS_TOKEN`(개인 액세스 토큰 — service_role과 다름! dashboard/account/tokens) setx + Claude Code 재시작 필요.
- 교사: `teacher@staff.yubongsystem.com` 생성 + `staff` 등록 완료(role teacher).
- 테스트용 세션/출석 데이터는 정리 완료(실데이터 무영향).

---

**요약**: 레포 pull → (필요시) Supabase MCP 연결 → `tools/`로 학생 계정 생성 → W3(admin.html, 저장키 cosmos_v3_admin) → 도메인 → 파일럿. 설계 권위본은 `DESIGN.md`.
