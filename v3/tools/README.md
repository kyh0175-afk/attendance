# 학생 계정 벌크 생성 도구

`students`(활성) 명단의 학번마다 Supabase Auth 계정을 만든다. **로컬 PC에서 한 번씩** 실행 (학기 초 / 신규 입학 시).

## ⚠️ service_role 키 주의

이 스크립트는 **service_role 키**(RLS를 전부 우회하는 관리자 키)가 필요하다.
- 위치: Supabase 대시보드 → **Project Settings → API → `service_role`** (Reveal 눌러 복사)
- **절대 커밋/공유/채팅 붙여넣기 금지.** 환경변수로만 넘긴다. 이 폴더의 어떤 파일에도 넣지 말 것.
- 유출되면 Settings → API 에서 즉시 rotate.

## 실행

```powershell
# 1) 이 폴더로 이동
cd v3/tools

# 2) 의존성 설치 (최초 1회)
npm install

# 3) service_role 키를 환경변수로 (이 터미널 세션에서만)
$env:SUPABASE_SERVICE_ROLE_KEY = "여기에_service_role_키"

# 4) 먼저 드라이런 — 실제로 만들지 않고 몇 명 생길지만 확인
node create-accounts.mjs --dry

# 5) 진짜 실행
node create-accounts.mjs
```

(Git Bash / macOS: `export SUPABASE_SERVICE_ROLE_KEY="..."`)

## 동작

- 이메일 = `{학번}@st.yubongsystem.com`, 초기 PIN = **학번**(기본), `must_change_pin=true`
- 이미 있는 계정은 건너뜀 → **여러 번 돌려도 안전**(신규만 추가)
- 학생 안내: v3 접속 → 학번 + 초기 PIN(=학번) → 첫 로그인 시 새 PIN 설정

## 초기 PIN 전략

기본은 "PIN = 학번"이라 학생이 외우기 쉽지만, 친구가 학번을 알면 선점 위험이 있다(관리자 PIN 초기화로 복구 가능). 더 안전하게 하려면 `create-accounts.mjs` 상단 `PIN_STRATEGY`를 무작위 PIN으로 바꾸고 종이로 배부 — 파일 주석 참고.

## 개별 관리

- PIN 초기화 1명: 관리자 화면(W3, 예정)의 "PIN 초기화" 또는 대시보드 Auth에서 수동.
- 전출: `students.활성=false` 처리(계정은 남지만 로그인해도 볼 데이터 없음). 필요 시 대시보드에서 계정 삭제.
