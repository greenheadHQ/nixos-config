# Plan 026: 호환 미보장 애드온·문서 drift·인프라 잔재를 일괄 정리한다

> **Executor instructions**: Part A(repo 문서)는 에이전트가 직접 수행한다.
> **Part A는 PR #1157로 완료됐다** — Step 1·2는 이미 반영돼 있고, 아래 "Current state"
> 발췌의 줄 번호는 그 반영 이후 기준으로 갱신했다. 남은 것은 Part B/C다.
> Part B(Anki 앱 내 조작)는 운영자 GUI 절차이며 에이전트는 검증만 한다.
> Part C(minipc 잔재)는 에이전트가 ssh로 수행하되 삭제 전 실측을 반복한다.
> STOP conditions 발생 시 중단·보고. 완료 시 `plans/README.md` 갱신.
>
> **Drift check (run first)**:
> `git diff --stat a19daba3..HEAD -- anki-study/README.md anki-study/GUIDE.md`
> 변경이 있으면 "Current state" 발췌와 대조하고, 불일치 시 STOP.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW (문서 수정 + 명확히 잔재로 확정된 것만 제거. 애드온은 삭제 대신 비활성화 우선)
- **Depends on**: plans/024-anki-ankiweb-cutover.md (soft — 애드온 제거 등 앱 상태 변경은 동기화/사본 확보 후가 안전)
- **Category**: tech-debt + docs
- **Planned at**: commit `a19daba3`, 2026-07-05
- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/976 (epic #973)

## Why this matters

세 종류의 잔재가 남아 있다. (1) 2.1.65/23.10 시대에 멈춘 애드온 4종이 Anki
26.5에서 호환 미보장 상태로 로드된다 — 그중 2종은 본체 기능으로 대체 가능하다.
(2) `anki-study/GUIDE.md`가 깨진 임시 서버를 "현재 운영 방식"으로, 철거된
인프라를 존재하는 것으로 기술한다 — GUIDE는 후속 학습 세션에서 LLM에게 그대로
입력되는 문서라 drift가 곧 오작동이 된다. (3) minipc 빈 심링크 등 self-host
철거(PR #863)의 부스러기가 남아 다음 조사자를 헷갈리게 한다. 모두 Effort S로
닫을 수 있고, 닫으면 "문서=현실"이 회복된다.

## Current state

**애드온** (`~/Library/Application Support/Anki2/addons21/`, meta.json 실측 2026-07-05):

| ID | 이름 | max_point_version | 처분 |
|----|------|------------------|------|
| 1237621971 | Add Table | 65 (=2.1.65) | 본체 표 기능으로 대체 → 비활성화 |
| 2491935955 | Quick Colour Changing | 231000 (=23.10) | 본체 글자색 기능으로 대체 → 비활성화 |
| 318752047 | Add Hyperlink | 65 | 업데이트 확인 → 없으면 비활성화 |
| 24411424 | Customize Keyboard Shortcuts | 231000 | 업데이트 확인 → 없으면 운영자 판단 (커스텀 단축키 상실 트레이드오프) |

나머지 6종(Anki Note Linker, Enhanced Cloze, AnkiConnect, extended editor,
Set Added Date, AnkiWebView Inspector)은 **건드리지 않는다** — 최신이거나 저위험.
특히 **Enhanced Cloze(1990296174)는 749개 노트가 쓰는 KaTeX and Markdown Cloze
notetype과 연관된 핵심 의존이다 — 절대 제거 금지.**

**문서 drift** (`anki-study/`, HEAD `a19daba3` 기준):

- `anki-study/GUIDE.md:167` — `## 5. 호스팅 & 채점 흐름 (현재 운영 방식, Future Ideas는 별도)`
  이하가 "LLM이 `/tmp/<workspace>/<card>.html` 작성 → Python http.server로 minipc
  Tailscale IP에서 서빙 → POST `/submit`" 흐름을 현재형으로 기술. 실제로는
  `server.py`가 repo에 없고 issue #839가 NOT_PLANNED로 close됨 (close 코멘트:
  "재개 시 서버 실행 경로와 /submit·/rate 계약 복구 또는 static-only 강등을
  첫 작업으로 선행").
- `anki-study/GUIDE.md:179-193` §6 및 `anki-study/README.md:77-86` Future Ideas —
  "AnkiConnect 양방향 sync", "`homeserver.ankiStudy.*` 모듈"을 기존 인프라
  연장선처럼 기술. 실제로는 PR #863(`3508e203`, 2026-05-30)로 anki-sync-server /
  anki-connect / awesome-anki 모듈·스킬·시크릿이 전량 철거되어 재구축 비용이
  0에서 시작한다.
- `anki-study/README.md:71-75` "관련 자료"에 "hosting-anki 스킬 (셀프호스팅
  제거됨)" 표기는 이미 정확 — 유지.
- 운영 전제(동기화/백업 상태)를 기술하는 문장이 anki-study 문서 전체에 0건.

**minipc 잔재** (2026-07-05 ssh 실측):

- `/var/lib/anki-sync-server -> private/anki-sync-server` 심링크 (target 0바이트).
  서비스 유닛/27701 포트/컨테이너는 없음 — 심링크만 남았다.

**건드리지 않기로 확정된 것** (evidence 문서 "기각" 절):
prefs21.db의 옛 경로(`/Users/green/*`)·`last_loaded_profile_name='test'`는 pickle
직접 수정 위험 대비 이득 없음 — Anki 사용 중 자연 갱신된다. collection config의
`awesomeAnki.*` 키 2개와 미사용 notetype 8종은 무해한 데이터 — 제거 이득이
조작 위험보다 작아 보류.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 애드온 상태 확인 | `python3 -c "import json,glob,os; [print(os.path.basename(os.path.dirname(p)), json.load(open(p)).get('disabled', False)) for p in glob.glob(os.path.expanduser('~/Library/Application Support/Anki2/addons21/*/meta.json'))]"` | ID별 disabled 상태 목록 |
| repo 문서 lint | `bash tests/run-all-tests.sh` | FAILED 0 |
| minipc 심링크 확인 | `ssh minipc 'ls -la /var/lib/ \| grep -i anki'` | Step 전: 심링크 1줄 / Step 후: 출력 없음 |

## Scope

**In scope**:

- `anki-study/GUIDE.md` §5·§6, `anki-study/README.md` Future Ideas·운영 전제 단락 (repo 커밋)
- 애드온 4종의 업데이트 확인/비활성화 (운영자 GUI)
- minipc `/var/lib/anki-sync-server` 심링크 제거
- suspend 일관화: `🚧 일시중단::[책] 모던 리액트 Deep Dive` 덱의 미suspend 카드 16장 (운영자 GUI 일괄 suspend)

**Out of scope** (건드리지 말 것):

- 애드온 **삭제** — 이번 회차는 비활성화까지만 (한 달 뒤 문제없으면 삭제는 운영자 재량)
- Enhanced Cloze·AnkiConnect 등 나머지 6종 애드온
- prefs21.db·collection config·notetype 정리 — 위 "건드리지 않기로 확정" 참조
- GUIDE §1–§4·§7 (학습 원칙 부분 — 유효한 SSOT다), sessions/ 아카이브
- anki-study 재개 여부 결정 — 2026-07-05 운영자 결정은 "보류, 복습 습관 먼저" (plan 025 규칙 6)

## Git workflow

- Branch: `docs/anki-study-drift-cleanup` (repo 변경분인 Part A만 해당)
- Conventional commits (예: `docs(anki-study): GUIDE §5 시제 강등 + 철거된 인프라 전제 정정`)
- push/PR 생성은 운영자 지시 없이는 하지 않는다.

## Steps

### Step 1 (에이전트, Part A): GUIDE.md §5 시제 강등

`anki-study/GUIDE.md:167`의 섹션 제목과 도입부를 수정한다:

- 제목: `## 5. 호스팅 & 채점 흐름 (⚠️ 중단됨 — server.py 부재, #839 참조)`
- 섹션 첫 줄에 blockquote 추가:
  > **2026-07-05 현행화**: 아래 흐름은 2026-05-10 첫 세션의 기록이다. `server.py`는
  > repo에 없고 minipc의 Anki 인프라는 PR #863로 철거됐다. 학습 세션을 재개하려면
  > 첫 작업으로 서빙 경로 복구 또는 static-only 강등을 선행할 것 (issue #839
  > close 코멘트의 재개 조건).
- 본문 5줄(LLM이 …→ POST /rate)은 역사 기록으로 유지 (삭제하지 않는다).

**Verify**: `grep -n "중단됨" anki-study/GUIDE.md` → §5 제목 라인 히트.

### Step 2 (에이전트, Part A): Future Ideas에 인프라 철거 각주 + README 운영 전제 단락

1. `anki-study/GUIDE.md` §6 목록 위와 `anki-study/README.md` Future Ideas 목록
   위에 한 줄 각주 추가:
   `> ⚠️ AnkiConnect·homeserver 관련 항목은 PR #863(2026-05-30)로 self-host 인프라가 전량 철거되어, 착수 시 모듈·시크릿·vhost 재구축이 전제된다.`
2. `anki-study/README.md`의 "관련 자료" 섹션 앞에 새 섹션 추가:

   ```markdown
   ## 운영 전제 (2026-07-05 기준)

   - 데스크톱 Anki 26.5, 프로필 `greenheadHQ` 단일.
   - 동기화: plans/024 이행 **전** = 무동기화(로컬 단독) / 이행·검증 **후** =
     AnkiWeb. 현재 어느 쪽인지는 `plans/README.md`의 024 status 행이 판정 기준.
   - 백업: Anki 로컬 자동 .colpkg (같은 디스크). AnkiWeb 서버본은 024 완료·검증
     후에만 존재. 독립 오프사이트 백업은 시점 무관 **없음**.
   - 복습 운영 규칙은 `plans/025-anki-restart-protocol.md` Step 2가 SSOT.
   ```

**Verify**: `bash tests/run-all-tests.sh` → FAILED 0. `git diff --stat` →
anki-study/ 2개 파일만 변경.

### Step 3 (운영자, Part B): 애드온 업데이트 확인 후 비활성화

Anki → 도구 > 부가기능:

1. "업데이트 확인" 실행. Add Hyperlink(318752047)·Customize Keyboard
   Shortcuts(24411424)에 업데이트가 오면 적용하고 그 항목은 완료.
2. 업데이트가 없는 항목 처리:
   - Add Table(1237621971)·Quick Colour Changing(2491935955): **비활성화**
     (본체 에디터의 표 삽입·글자색 기능으로 대체 — 며칠 써보고 불편하면 재활성화).
   - Add Hyperlink: 비활성화 (링크는 본체 에디터 Ctrl/Cmd+K 계열로 갈음).
   - Customize Keyboard Shortcuts: 비활성화 시 커스텀 단축키가 전부 풀린다 —
     운영자가 현재 커스텀 단축키에 의존 중이면 "유지(경고 감수)"를 선택해도
     된다. 선택 결과를 보고에 기록.
3. Anki 재시작.

**Verify** (에이전트): 애드온 상태 확인 명령 → 1237621971·2491935955 (및 선택에
따라 318752047·24411424) `disabled: True`. 운영자에게 에디터에서 표 삽입·글자색이
본체 기능으로 동작하는지 1회 확인 요청.

### Step 4 (운영자, Part B): 리액트 덱 suspend 일관화

Anki 브라우저에서 검색: `deck:"🚧 일시중단::[책] 모던 리액트 Deep Dive" -is:suspended`
→ 전체 선택 → 일시정지(suspend). 16장 내외가 대상이다.

**Verify** (에이전트): `curl -s localhost:8765 -X POST -d '{"action":"findCards","version":6,"params":{"query":"deck:\"🚧 일시중단::[책] 모던 리액트 Deep Dive\" -is:suspended"}}'` → `result` 배열 길이 0.

### Step 5 (에이전트, Part C): minipc 심링크 제거

```bash
ssh minipc 'test -L /var/lib/anki-sync-server && readlink /var/lib/anki-sync-server'
# 기대: private/anki-sync-server — 심링크가 아니거나 target이 다르면 STOP
ssh minipc 'sudo find /var/lib/private/anki-sync-server -mindepth 1 -print -quit 2>/dev/null | grep -q . && echo NOT-EMPTY || echo EMPTY'
```

`EMPTY`일 때만 삭제한다 (`NOT-EMPTY`면 STOP — 감사 시점 이후 데이터가 생긴
것이므로 내용 보고 먼저). 삭제는 `rm -rf`가 아니라 `rmdir`로 — 비어 있지
않으면 실패하는 것 자체가 마지막 안전장치다:

```bash
ssh minipc 'sudo rm /var/lib/anki-sync-server && sudo rmdir /var/lib/private/anki-sync-server'
```

(sudo 비밀번호가 필요해 비대화형으로 실패하면 운영자에게 명령을 전달하고 실행을
요청한다 — CLAUDE.md의 ssh 규칙상 Mac에서 minipc 접속은 허용.)

**Verify**: `ssh minipc 'ls /var/lib/ | grep -i anki; ls /var/lib/private/ 2>/dev/null | grep -i anki'` → 출력 없음.

## Test plan

- Part A는 문서 변경 — repo 게이트 `bash tests/run-all-tests.sh` FAILED 0이 테스트.
- Part B/C는 위 Verify의 실측 명령이 테스트를 대신한다.

## Done criteria

- [ ] `anki-study/GUIDE.md` §5 제목에 중단 표기 + §6/README Future Ideas에 철거 각주
- [ ] `anki-study/README.md`에 "운영 전제" 섹션 존재
- [ ] `bash tests/run-all-tests.sh` FAILED 0, anki-study/ 외 파일 무변경
- [ ] Add Table·Quick Colour 비활성화 (+ 나머지 2종은 처분 결과 기록)
- [ ] 리액트 덱 미suspend 카드 0장
- [ ] minipc에 anki 관련 경로 잔존 0건
- [ ] `plans/README.md` 026 행 갱신

## STOP conditions

- GUIDE.md/README.md의 인용 위치·문구가 Current state와 불일치 (drift).
- 애드온 비활성화 후 Anki가 기동 실패하거나 에디터가 깨짐 — 즉시 해당 애드온
  재활성화 후 보고 (비활성화는 가역적이다 — 이것이 삭제 대신 비활성화를 택한 이유).
- minipc의 `/var/lib/anki-sync-server`가 빈 심링크가 아니라 **데이터가 있는
  디렉토리**로 실측됨 — 삭제 금지, 내용 보고 먼저.
- Enhanced Cloze/AnkiConnect를 건드려야 하는 상황으로 보임 — 범위 밖, 중단.

## Maintenance notes

- 비활성화한 애드온은 1개월 뒤 불편이 없으면 삭제해도 된다 (운영자 재량, plan 불요).
- 이후 새 애드온 설치 시 기준: `max_point_version`이 현 Anki 버전대를 커버하고
  최근 1년 내 갱신된 것만.
- GUIDE.md는 "다음 세션 LLM 입력" 문서다 — anki-study 관련 상태가 바뀌면
  (재개, 서버 복구 등) §5 주석과 README "운영 전제"를 같은 커밋에서 갱신할 것.
