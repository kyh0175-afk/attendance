// 코스모스 출석 v3 — 공용 설정
// publishable(anon) key는 공개용 — RLS가 실제 접근을 통제한다.
export const SUPABASE_URL = 'https://rxsmmwqekrtbstcjbagj.supabase.co';
export const SUPABASE_KEY = 'sb_publishable_h7o2vnvgu7Akrg87cAYSkg__DA-KRpn';

// 학생 가상 이메일 도메인 ({학번}@st.yubongsystem.com)
export const EMAIL_DOMAIN = 'st.yubongsystem.com';

// 교사 공용 계정 (PIN만으로 로그인 — 계정은 대시보드 생성 + staff 등록)
export const STAFF_EMAIL = 'teacher@staff.yubongsystem.com';

// 관리자 계정 (admin.html 전용 — staff 테이블 role='admin' 등록 필요)
export const ADMIN_EMAIL = 'admin@staff.yubongsystem.com';

// 운영 프로그램 · 장소
export const PROGRAMS = ['방과후 독서시간', '야간 독서시간', '심야 독서시간', '토요일 독서시간', '일요일 독서시간'];
export const ROOMS = ['아우름', '교과1실', '해오름', '리케이온'];

// ── 퇴실 코드 자동 발급 ──
// 프로그램별 종료 시각. 세션 시작 화면의 '종료 시각'을 자동으로 채우고,
// 그 시각 AUTO_EXIT_LEAD_MIN분 전에 퇴실 코드를 자동 발급한다.
// ★ 교사가 화면에서 수정할 수 있으므로 여기 값은 '기본값'일 뿐이다.
export const PROGRAM_END = {
  '방과후 독서시간': '18:20',
  '야간 독서시간': '21:30',
  '심야 독서시간': '23:00',
  '일요일 독서시간': '17:30',
};

// 토요일은 오전(08:30~12:30)·오후(13:30~17:30) 두 타임인데 프로그램명이 하나뿐이라
// 이름만으로는 종료 시각을 정할 수 없다 → 세션을 여는 시각으로 추정한다.
// 13시 전에 열면 오전, 그 이후면 오후. 어긋나면 교사가 화면에서 고치면 된다.
export const SATURDAY_END = { am: '12:30', pm: '17:30' };
export const SATURDAY_SPLIT_HOUR = 13;

// 종료 몇 분 전에 자동 발급할지 (2026-08-01 확정: 5분 전)
export const AUTO_EXIT_LEAD_MIN = 5;

// 프로그램(+현재 시각)으로 종료 시각 'HH:MM' 추정. 모르면 빈 문자열.
export function guessEndTime(program, now) {
  if (program === '토요일 독서시간') {
    var d = now || new Date();
    return d.getHours() < SATURDAY_SPLIT_HOUR ? SATURDAY_END.am : SATURDAY_END.pm;
  }
  return PROGRAM_END[program] || '';
}

export const APP_NAME = '코스모스 출석';
