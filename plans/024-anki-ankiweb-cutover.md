# Plan 024: Anki를 AnkiWeb 동기화로 실제 전환한다 (2026-05-30 결정의 이행 완료)

> **Executor instructions**: 이 plan은 **운영자(사용자) GUI 절차 + 에이전트 검증**의
> 혼합 runbook이다 (관례: `plans/017-maintenance-window-runbook.md`). GUI 단계는
> 운영자가 수행하고, 에이전트는 각 검증 명령으로 상태를 확인·보고한다.
> STOP conditions 발생 시 즉시 중단하고 보고 — 임의 진행 금지.
> 완료 시 `plans/README.md`의 status row를 갱신한다.
>
> **Drift check (run first)**: 이 plan의 대상은 repo 파일이 아니라 로컬 Anki
> 프로필이다. 아래 "현재 상태 재확인" 명령을 실행해 Current state와 다르면
> (특히 syncKey가 이미 존재하면) STOP — 이미 이행됐거나 상황이 바뀐 것이다.

## Status

- **Priority**: P1 (데이터 손실 방어 — 다른 모든 Anki plan에 선행)
- **Effort**: S
- **Risk**: MED (최초 sync에서 방향(Upload/Download)을 잘못 고르면 로컬 컬렉션이 빈 서버본으로 덮일 수 있다 — 절차로 방어)
- **Depends on**: none
- **Category**: migration (결정 이행)
- **Planned at**: commit `a19daba3`, 2026-07-05
- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/974 (epic #973)

## Why this matters

3년치 학습 데이터(811노트, revlog 9,272건, 미디어 194MB)가 Mac 디스크 한 장에만
존재한다. 로컬 자동 백업(.colpkg)도 같은 디스크의 `~/Library` 하위라 디스크
장애·분실 시 함께 소실된다. 2026-05-30 self-host 인프라 전면 제거(PR #863) 때
"AnkiWeb 동기화로 충분"을 근거로 삼았지만 **AnkiWeb 로그인은 그 후 한 번도
이행되지 않았다** (결정 원문: 세션 로그, 실측: prefs21.db syncKey 없음).
이 plan이 끝나면 결정과 현실의 drift가 닫히고, 컬렉션+미디어의 사본이 AnkiWeb
서버에 상시 존재하며, iPhone(AnkiMobile/AnkiWeb) 접근도 열린다.

## Current state

- 프로필: `~/Library/Application Support/Anki2/greenheadHQ/` (유일 프로필)
- prefs21.db (pickle, 2026-07-05 실측): `syncKey: None`, `syncUser: None`,
  `customSyncUrl: ''`, `hostNum: 0`, **`autoSync: True`, `syncMedia: True`**
  — 로그인만 되면 자동 동기화가 즉시 동작하는 설정이다.
- Time Machine: 목적지 미구성 (`tmutil destinationinfo` → "No destinations configured").
- Anki 26.5. FSRS 활성, 2026-07-05에 파라미터 최적화 실행됨.
- 근거 상세: `plans/anki-audit-evidence/2026-07-05-audit.md`

**현재 상태 재확인** (에이전트, 실행 전 필수 — syncKey 값은 절대 출력하지 말 것):

```bash
python3 - <<'EOF'
import sqlite3, pickle, shutil, os, tempfile
src = os.path.expanduser("~/Library/Application Support/Anki2/prefs21.db")
tmp = os.path.join(tempfile.mkdtemp(), "prefs21.db")
shutil.copy(src, tmp)  # Anki 실행 중 잠금 회피: 사본으로 읽기
db = sqlite3.connect(tmp)
for name, blob in db.execute("select cast(name as text), data from profiles"):
    if name == "_global": continue
    d = pickle.loads(blob)
    print(f"profile={name} syncKey={'SET' if d.get('syncKey') else 'NONE'} "
          f"syncUser={'SET' if d.get('syncUser') else 'NONE'} "
          f"customSyncUrl={d.get('customSyncUrl')!r} syncMedia={d.get('syncMedia')}")
EOF
```

기대: `profile=greenheadHQ syncKey=NONE syncUser=NONE customSyncUrl='' syncMedia=True`
→ `syncKey=SET`이면 STOP (이미 이행됨).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| sync 상태 확인 | 위 "현재 상태 재확인" 스크립트 | Step별 기대값 참조 |
| 안전 사본 무결성 | `python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).testzip()" <colpkg 경로>` | 출력 없음(None), exit 0 |
| Anki 실행 여부 | `pgrep -x Anki >/dev/null && echo RUNNING \|\| echo STOPPED` | 문맥별 |
| AnkiConnect로 컬렉션 확인 | `curl -s localhost:8765 -X POST -d '{"action":"getNumCardsReviewedToday","version":6}'` | `{"result": <숫자>, "error": null}` (Anki 실행 중일 때) |

## Scope

**In scope**:

- AnkiWeb 계정 상태 확인/생성, Anki 데스크톱 로그인, 최초 full sync(Upload), 미디어 sync 완료 확인
- 이행 직전 오프라인 안전 사본 1부를 **다른 물리 매체/클라우드**에 확보
- `plans/README.md` status 갱신

**Out of scope** (건드리지 말 것):

- collection 내용 변경 일체 (노트/카드/덱/설정) — 025~027의 영역
- self-host sync server 재구축 — 2026-05-30 제거 결정 유지 (2026-07-05 운영자 재확인)
- Time Machine/restic 등 상시 로컬 백업 체계 수립 — 필요 시 별도 plan (Maintenance notes 참조)
- prefs21.db 직접 수정 — 절대 금지 (pickle 손상 위험)

## Steps

### Step 1 (에이전트): 사전 안전 사본 확보

최초 sync 방향 실수라는 유일한 파괴 시나리오에 대비해, **이행 직전** 상태의
사본을 Mac 디스크 밖으로 1부 내보낸다.

1. 운영자에게 Anki 종료를 요청한다 (`pgrep -x Anki` → STOPPED 확인).
2. 최신 자동 백업을 복사한다:
   ```bash
   B=$(ls -t ~/Library/Application\ Support/Anki2/greenheadHQ/backups/*.colpkg | head -1)
   cp "$B" ~/Desktop/anki-pre-ankiweb-cutover.colpkg
   ```
   주의: 자동 `.colpkg` 백업은 **미디어 미포함**이다. 미디어 폴더도 함께 보존:
   ```bash
   tar -czf ~/Desktop/anki-media-pre-cutover.tar.gz -C ~/Library/Application\ Support/Anki2/greenheadHQ collection.media
   ```
3. 두 파일을 Mac 외 위치(iCloud Drive, 외장 디스크, 또는 `scp`로 minipc 등)로
   복사한다. 위치는 운영자가 지정.

**Verify**: colpkg 무결성 명령 exit 0 + `tar -tzf …tar.gz | wc -l` → 1232 내외 +
운영자가 외부 위치 복사 완료를 확인.

### Step 2 (운영자): AnkiWeb 계정 확인/생성

<https://ankiweb.net> 에서 로그인 시도. 계정이 없거나 기억나지 않으면:

- 새 계정 생성 (이메일 인증 포함), 또는
- 비밀번호 재설정으로 기존 계정 복구.

기존 계정이 있고 **그 서버 컬렉션에 데이터가 남아 있다면** (과거 사용 흔적)
→ 웹에서 덱 목록을 확인하고 내용을 보고한 후 Step 3의 방향 선택에 반영한다.

**Verify**: ankiweb.net 웹 UI에서 로그인 성공. 서버측 덱 상태(비어 있음 / 내용
있음)를 확인해 기록.

### Step 3 (운영자): 데스크톱 로그인 + 최초 sync — 방향 선택이 핵심

1. Anki 실행 → sync 버튼(우상단 ⟳) 클릭 → AnkiWeb 계정으로 로그인.
2. 방향 선택 다이얼로그가 뜨면 (한쪽이 비어 있거나 계보가 다르면 뜬다):
   **반드시 "AnkiWeb에 업로드(Upload to AnkiWeb)"를 선택한다.**
   로컬(greenheadHQ)이 유일한 진본이다 — "다운로드"를 선택하면 로컬이 서버본
   (대개 빈 컬렉션)으로 덮인다.
   - 예외: Step 2에서 서버에 의미 있는 데이터가 발견된 경우 → STOP, 병합
     전략을 별도 논의.
3. 미디어 동기화(194MB)가 백그라운드로 진행된다. 첫 업로드는 수 분 걸릴 수
   있다. Anki를 켜둔 채 완료를 기다린다 (`도구 > 미디어 확인`이 아니라 sync
   상태 표시 기준).

**Verify** (운영자): sync 완료 후 ankiweb.net 웹에서 덱 6개 이상과 카드 수가
로컬과 일치하게 보임 (예: "[책] 모던 자바스크립트 Deep Dive" 505장 계열).

### Step 4 (에이전트): 이행 상태 최종 검증

1. "현재 상태 재확인" 스크립트 재실행 →
   기대: `syncKey=SET syncUser=SET customSyncUrl='' syncMedia=True`
   (**주의**: SET/NONE 판정만 출력하는 위 스크립트를 그대로 사용. syncKey/hkey
   값 자체를 출력·기록하는 것은 금지 — 자격증명이다.)
2. `customSyncUrl`이 빈 문자열 그대로인지 확인 (과거 self-host URL이 어떤
   경로로든 재유입되지 않았음을 보증).
3. 운영자에게 iPhone 접근 의사를 확인 — 원하면 AnkiMobile(유료) 또는
   ankiweb.net 모바일 웹 로그인을 안내 (본 plan의 필수 게이트는 아님).

**Verify**: 1의 기대 출력 + 운영자의 웹 확인 보고.

## Test plan

이 plan은 코드가 아니라 운영 절차라 자동 테스트는 없다. 검증 게이트가 테스트를
대신한다: Step 1 사본 무결성(zip testzip), Step 3 웹측 덱/카드 수 일치,
Step 4 prefs 상태 3필드 일치.

## Done criteria

- [ ] 외부 위치에 `anki-pre-ankiweb-cutover.colpkg` + 미디어 tar 사본 존재 (운영자 확인)
- [ ] prefs 재확인 스크립트 출력: `syncKey=SET syncUser=SET customSyncUrl='' syncMedia=True`
- [ ] ankiweb.net 웹에서 로컬과 동일한 덱 구조·카드 수 확인 (운영자 보고)
- [ ] syncKey/계정 비밀번호 등 자격증명 값이 어떤 산출물에도 기록되지 않음
- [ ] `plans/README.md` 024 행 status 갱신

## STOP conditions

- 재확인 스크립트에서 `syncKey=SET` (이미 이행됨 — 상태 보고 후 종료).
- `customSyncUrl`이 빈 문자열이 아님 (과거 self-host 잔재 발견 — 원인 파악 먼저).
- Step 2에서 기존 AnkiWeb 계정 서버측에 의미 있는 덱/카드가 존재 (Upload가
  서버본을 덮는다 — 병합 전략 별도 논의 필요).
- Step 3에서 운영자가 방향 다이얼로그의 문구를 확신하지 못함 — 추측으로
  누르지 말고 다이얼로그 전문을 보고.
- Step 1의 사본 확보가 어떤 이유로든 실패 — 사본 없이 sync 진행 금지.

## Maintenance notes

- **AnkiWeb은 동기화이지 백업이 아니다**: 잘못된 로컬 변경도 그대로 전파된다.
  로컬 자동 백업(.colpkg 50개 보관)이 실수 복구를, AnkiWeb이 디스크 장애를
  각각 담당하는 이원 구조가 된다. 오프사이트 **독립** 백업(예: `.colpkg`를
  restic→R2로 — `plans/020-offsite-restic-r2.md` 스택 재사용)은 명시적으로
  이번 범위에서 제외했다. AnkiWeb 이행 후에도 필요성이 느껴지면 별도 plan으로.
- AnkiWeb 무료 계정은 장기 미접속(수개월~1년) 시 서버 컬렉션이 정리될 수 있다
  — plan 025의 복습 재개가 자연스러운 방어다.
- 오늘(2026-07-05) 사용자가 codex로 진단하던 "Anki 실행 시 네트워크 에러 팝업"은
  본 감사에서 원인 미확정 (sync는 로그인 자체가 없어서 시도되지 않는 상태였다 —
  업데이트 체크/애드온 체크가 후보). 로그인 후 팝업 양상이 바뀌면 plan 026의
  애드온 정리와 연계해 재진단.
