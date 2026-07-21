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
| **다음: 학생 계정 벌크 생성** | ⏳ `tools/` 준비됨 — 실행만 |
| W3 (관리자 화면·통계) | ⬜ 미착수 |
| W4 (파일럿) · 도메인 연결 | ⬜ 미착수 |

**바로 다음 할 일**: `v3/tools/`의 계정 생성 스크립트를 로컬에서 실행(582명 계정) → 그 다음 W3.

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
  assets/js/
    config.js           SUPABASE_URL/KEY(공개 anon), EMAIL_DOMAIN, STAFF_EMAIL, PROGRAMS, ROOMS
    sb.js               Supabase 클라이언트 + auth + DAL + setAuthStorageKey()
    student.js          학생 페이지 컨트롤러
    teacher.js          교사 페이지 컨트롤러
  sw.js                 서비스워커(앱셸 캐시, 네트워크우선)
  manifest.webmanifest  PWA
  icon-*.png, icon.svg  아이콘(v2 복사)
  DESIGN.md             설계서(권위본)
  HANDOFF.md            이 문서
  tools/                계정 벌크생성 (create-accounts.mjs, README.md, package.json)
```

**디자인 시스템**(계승할 것): 따뜻한 크림/브라운(v2 유지) + "독서등" 다크 히어로 카드 + 램프골드 액센트(#c7994f). 모션=카운트업·스프링 뷰전환·촉각버튼·햅틱·reduced-motion. 폰트=Cormorant Garamond(워드마크)+IBM Plex Sans KR. ★광원(글로우) 효과는 사자님이 뺐음 — 넣지 말 것.

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

1. **학생 계정 생성** — `v3/tools/README.md` 따라 로컬 실행. (582명, `--dry` 먼저)
2. **W3 관리자 화면 (`admin.html` + `admin.js`)**:
   - ★ auth 저장키 `cosmos_v3_admin`.
   - 로그인(관리자). 명단 관리(활성/PIN초기화 — PIN초기화는 계정 password 갱신, Admin API 필요 → 로컬스크립트나 Edge Function; 브라우저에서 service_role 금지).
   - **통계**: 퇴실율, `퇴실미확인` 집계(학생별·기간별), 반복 미퇴실자.
   - (선택) v2 관리자 기능 이식 — 다만 v2 admin은 그대로 살아있으니 급하지 않음.
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

- 학생 테스트 계정: 대시보드에서 수동 생성했던 것(예 `99999@st.yubongsystem.com`)이 있을 수 있음. 실 학생 계정은 아직 미생성(§6-1에서 생성).
- 교사: `teacher@staff.yubongsystem.com` 생성 + `staff` 등록 완료(role teacher).
- 테스트용 세션/출석 데이터는 정리 완료(실데이터 무영향).

---

**요약**: 레포 pull → (필요시) Supabase MCP 연결 → `tools/`로 학생 계정 생성 → W3(admin.html, 저장키 cosmos_v3_admin) → 도메인 → 파일럿. 설계 권위본은 `DESIGN.md`.
