// 코스모스 출석 v3 — 공용 설정
// publishable(anon) key는 공개용 — RLS가 실제 접근을 통제한다.
export const SUPABASE_URL = 'https://rxsmmwqekrtbstcjbagj.supabase.co';
export const SUPABASE_KEY = 'sb_publishable_h7o2vnvgu7Akrg87cAYSkg__DA-KRpn';

// 학생 가상 이메일 도메인 ({학번}@st.yubongsystem.com)
export const EMAIL_DOMAIN = 'st.yubongsystem.com';

// 교사 공용 계정 (PIN만으로 로그인 — 계정은 대시보드 생성 + staff 등록)
export const STAFF_EMAIL = 'teacher@staff.yubongsystem.com';

// 운영 프로그램 · 장소
export const PROGRAMS = ['방과후 독서시간', '야간 독서시간', '심야 독서시간', '토요일 독서시간', '일요일 독서시간'];
export const ROOMS = ['아우름', '교과1실', '해오름', '리케이온'];

export const APP_NAME = '코스모스 출석';
