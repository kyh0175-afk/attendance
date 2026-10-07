"""감독표(OneDrive 공유 엑셀) → Supabase supervisor_slots 동기화.

GitHub Actions(.github/workflows/supervisor-sync.yml)가 하루 두 번 실행한다.
- 공유 링크(익명 보기)를 열어 손님 쿠키를 받은 뒤 &download=1 로 xlsx를 받는다.
- 이번 달·다음 달 시트(예: "26년 10월")에서 날짜(A열)와 감독 칸(D·G·M·N·O·P·Q·R·S열)을 읽는다.
- 머리줄이 2026-10 감독표 형식과 다르면 그 시트는 읽지 않고 실패로 끝낸다(열이 밀린 채 잘못 채우지 않도록).
- 공개 레포라 실행 로그가 공개된다 → 교사 이름은 출력하지 않고 건수만 남긴다.

환경 변수
  SUPERVISOR_XLSX_URL    공유 링크(Secrets)
  SUPERVISOR_SYNC_TOKEN  동기화 토큰(Secrets) — 서버 sync_tokens에는 해시만 있다
  SUPABASE_URL, SUPABASE_KEY  (publishable 키, 공개값)
옵션
  --file 경로    다운로드 대신 로컬 xlsx 사용(시험용)
  --dry-run 경로 서버에 보내지 않고 보낼 JSON을 파일로 저장
"""
import argparse
import datetime as dt
import io
import json
import os
import re
import sys

import openpyxl

KST = dt.timezone(dt.timedelta(hours=9))

# 0부터 센 열 번호 → (프로그램, 장소그룹, 시간대)
COLS = {
    3: ('방과후 독서시간', '아우름+교과1실', ''),   # D
    6: ('방과후 독서시간', '해오름+리케이온', ''),   # G
    12: ('야간 독서시간', '아우름+교과1실', ''),     # M (코스모스반)
    13: ('야간 독서시간', '해오름+리케이온', ''),     # N
    14: ('토요일 독서시간', '리케이온', '오전'),       # O
    15: ('토요일 독서시간', '리케이온', '오후'),       # P
    16: ('일요일 독서시간', '리케이온', '오전'),       # Q
    17: ('일요일 독서시간', '리케이온', '오후'),       # R
    18: ('심야 독서시간', '리케이온', ''),             # S
}
NAME_RE = re.compile(r'[가-힣]{2,5}[A-Za-z]?')


def cell(rows, r, c):
    try:
        v = rows[r][c]
    except IndexError:
        return ''
    return '' if v is None else str(v).replace('　', ' ').strip()


def header_ok(rows):
    """2026-10 감독표 머리줄과 같은 배치인지 확인(행·열은 0부터)."""
    checks = [
        cell(rows, 2, 0) == '날짜',
        cell(rows, 2, 2).startswith('방과후'),
        '코스모스' in cell(rows, 2, 12),
        '주말' in cell(rows, 2, 14),
        cell(rows, 2, 18).startswith('심야'),
        '아우름' in cell(rows, 5, 3),
        '해오름' in cell(rows, 5, 6),
        '아우름' in cell(rows, 4, 12),
        '해오름' in cell(rows, 4, 13),
        '토' in cell(rows, 4, 14) and '오전' in cell(rows, 4, 14),
        '토' in cell(rows, 4, 15) and '오후' in cell(rows, 4, 15),
        '일' in cell(rows, 4, 16) and '오전' in cell(rows, 4, 16),
        '일' in cell(rows, 4, 17) and '오후' in cell(rows, 4, 17),
    ]
    return all(checks)


def pick_sheet(wb, year, month):
    base = f'{year % 100}년 {month}월'
    names = [ws.title for ws in wb.worksheets]
    cands = [n for n in names if n == base] + sorted(
        [n for n in names if n.startswith(base) and n != base and '감독신청' not in n and not n[len(base):len(base) + 1].isdigit()],
        key=len)
    for n in cands:
        rows = [tuple(r) for r in wb[n].iter_rows(values_only=True)]
        if header_ok(rows):
            return n, rows
    return (cands[0] if cands else None), None


def parse_date(v, year, month):
    if isinstance(v, dt.datetime):
        return v.date()
    if isinstance(v, dt.date):
        return v
    m = re.search(r'(\d{1,2})\s*월\s*(\d{1,2})\s*일', str(v or ''))
    if m:
        try:
            return dt.date(year, int(m.group(1)), int(m.group(2)))
        except ValueError:
            return None
    return None


def rows_for_month(wb, year, month):
    name, rows = pick_sheet(wb, year, month)
    if name is None:
        return None, []
    if rows is None:
        raise SystemExit(f'[중단] "{name}" 시트 머리줄이 감독표 형식(2026-10 기준)과 달라 읽지 않았어요. 열 배치를 확인하세요.')
    out = []
    weekend = {}   # (그 주 토·일 날짜, 열) → 이름. 감독표는 평일 줄만 있고 토·일 감독은 그 주 평일 줄(보통 첫 줄)에 적는다.
    for r in range(6, len(rows)):
        d = parse_date(rows[r][0] if rows[r] else None, year, month)
        if not d or d.month != month:
            continue
        for c, (prog, group, slot) in COLS.items():
            v = cell(rows, r, c)
            who = v if NAME_RE.fullmatch(v) else None
            if prog in ('토요일 독서시간', '일요일 독서시간'):
                # 2026-08·10 실제 세션 기록으로 확인: 8/17(월) 줄의 토 오후 = 8/22 감독, 10/1(목) 줄의 토 오전 = 10/3 감독
                target = d + dt.timedelta(days=(5 if prog.startswith('토') else 6) - d.weekday())
                key = (target.isoformat(), c)
                if who or key not in weekend:
                    weekend[key] = weekend.get(key) or who   # 그 주 첫 번째로 적힌 이름을 쓴다
                continue
            out.append({'날짜': d.isoformat(), '프로그램': prog, '장소그룹': group, '시간대': slot, '교사명': who})
    for (day, c), who in sorted(weekend.items()):
        prog, group, slot = COLS[c]
        out.append({'날짜': day, '프로그램': prog, '장소그룹': group, '시간대': slot, '교사명': who})
    return name, out


def download(url):
    import requests
    s = requests.Session()
    s.headers['User-Agent'] = 'Mozilla/5.0 (cosmos-attendance supervisor sync)'
    r = s.get(url, timeout=60)
    r.raise_for_status()
    dl = url + ('&' if '?' in url else '?') + 'download=1'
    r = s.get(dl, timeout=60)
    r.raise_for_status()
    if not r.content.startswith(b'PK'):
        raise SystemExit(f'[중단] 엑셀이 아닌 응답을 받았어요(HTTP {r.status_code}, {r.headers.get("content-type")}). 공유 링크가 만료됐거나 권한이 바뀌었을 수 있어요.')
    return r.content


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--file')
    ap.add_argument('--dry-run')
    ap.add_argument('--today')   # 시험용 YYYY-MM-DD
    a = ap.parse_args()

    data = open(a.file, 'rb').read() if a.file else download(os.environ['SUPERVISOR_XLSX_URL'])
    wb = openpyxl.load_workbook(io.BytesIO(data), data_only=True, read_only=True)

    today = dt.date.fromisoformat(a.today) if a.today else dt.datetime.now(KST).date()
    months = [(today.year, today.month)]
    nxt = (today.replace(day=1) + dt.timedelta(days=32))
    months.append((nxt.year, nxt.month))

    payload = []
    for y, m in months:
        name, rows = rows_for_month(wb, y, m)
        if name is None:
            print(f'{y}-{m:02d}: 시트 없음(건너뜀)')
            continue
        filled = sum(1 for x in rows if x['교사명'])
        days = len({x['날짜'] for x in rows})
        print(f'{y}-{m:02d}: 시트 "{name}" · 날짜 {days}일 · 감독 칸 {filled}개')
        payload += rows
    # 주말이 두 달 시트에 걸치면 한쪽은 빈칸일 수 있다 → 같은 칸은 이름이 있는 쪽을 남긴다(빈칸이 이름을 지우지 않게)
    merged = {}
    for x in payload:
        k = (x['날짜'], x['프로그램'], x['장소그룹'], x['시간대'])
        if k not in merged or (x['교사명'] and not merged[k]['교사명']):
            merged[k] = x
    payload = list(merged.values())
    if not payload:
        raise SystemExit('[중단] 읽은 감독 정보가 없어요.')

    if a.dry_run:
        json.dump(payload, open(a.dry_run, 'w', encoding='utf-8'), ensure_ascii=False)
        print('dry-run 저장:', len(payload), '행')
        return

    import requests
    url = os.environ.get('SUPABASE_URL', 'https://rxsmmwqekrtbstcjbagj.supabase.co').rstrip('/')
    key = os.environ['SUPABASE_KEY']
    r = requests.post(f'{url}/rest/v1/rpc/sync_supervisor_slots',
                      headers={'apikey': key, 'Authorization': f'Bearer {key}', 'Content-Type': 'application/json'},
                      data=json.dumps({'p_token': os.environ['SUPERVISOR_SYNC_TOKEN'], 'p_rows': payload}, ensure_ascii=False).encode('utf-8'),
                      timeout=60)
    if r.status_code >= 300:
        raise SystemExit(f'[실패] 서버 반영 HTTP {r.status_code}: {r.text[:300]}')
    print('서버 반영:', r.text)


if __name__ == '__main__':
    main()
