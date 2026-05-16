# `.claude/plans/` 디렉토리 정책

본 디렉토리는 `plan-with-questions` 스킬의 `for_action` 모드가 만드는 **SSOT plan 파일** (`.claude/plans/<slug>.md`) 의 위치다. 동시에 Claude Code harness의 plan-mode runtime이 떨어뜨리는 **transient plan buffer** (`<slug>-<8hex>.md`) 도 같은 디렉토리에 누적된다. 두 종류를 구분해 다루는 것이 본 정책의 목표다.

연관 이슈: #756 (P0 — 본 README), #756 P1 (transient buffer GC 정책/훅, 별도 사이클).

## Plan 파일 bind 원칙

새 plan을 만들기 전에 `plan-with-questions/modes/for_action.md:120-122` 규약에 따라 같은 source(이슈 ref) + non-terminal Status를 가진 기존 SSOT plan이 있는지 먼저 검색한다. 있으면 새 파일을 만들지 않고 그 파일에 bind 한 뒤 `Resume From` / `Last Completed Step` / `DA State` 로 재개한다. 새 파일이 필요한 collision (terminal Status 또는 unrelated source) 일 때만 `-2`, `-3` 같은 숫자 suffix로 collision을 해소한다. 무작위 hex suffix (`<slug>-<8hex>.md`) 는 SSOT plan을 위한 합법 파일명이 아니다.

## Transient buffer 식별 기준

파일명이 `<prefix>-<8hex>.md` 형식 (8자리 hex suffix) 이면 plan-mode runtime이 자동 생성한 transient plan buffer다. plan-with-questions 스킬 문서는 이 buffer를 새 SSOT plan으로 **승격하지 말라**고만 규정하고 (`modes/for_action.md:136`, `references/runtime-boundaries.md:76-78`), 정리(GC) 주체는 명시하지 않는다. 따라서 buffer는 무한 누적되는 경향이 있다 (#756 P1이 정리 정책/훅을 다룰 예정).

본 README 작성 시점 실측: hex 변종 누적이 가장 많은 prefix는 동일 topic의 SSOT plan canonical과 공존한다. canonical 식별은 아래 snippet 출력의 prefix 중 `<prefix>.md` (suffix 없음) 가 디렉토리에 존재하면 그것이 canonical SSOT plan이다.

`-agent-<NHex>` 같은 다른 패턴 (예: `cosmic-booping-peach-agent-a1cbb08.md`) 도 일부 존재하나 2026-02-28 이후 추가 생성되지 않는 historical artifacts다 (과거 Claude Code sub-agent 산출물). 본 README의 식별 기준에 포함하지 않는다. P1에서 별도 일회성 정리 대상으로 분리한다.

## Prefix별 hex 변종 집계 snippet

다음 one-liner를 main checkout의 repo root에서 실행하면 prefix별 hex 변종 누적 수를 내림차순으로 본다.

```bash
find "${1:-.claude/plans}" -maxdepth 1 -type f \
  -name '*-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].md' \
  | sed -E 's|^.*/||; s/-[0-9a-f]{8}\.md$//' \
  | sort | uniq -c | sort -rn
```

이 snippet은 실측 plan 누적 디렉토리 점검용이다. 다른 머신 또는 다른 디렉토리에서 실행하려면 첫 인자로 경로를 넘긴다 (`bash <(...) /other/path` 또는 stdin 파이프). hex suffix 파일만 입력으로 삼으므로 canonical `<prefix>.md` 는 집계에 포함되지 않는다 (의도). GNU/BSD find 공통 형태로 macOS 와 NixOS 양쪽에서 동작한다.

## DoD 실행 컨텍스트

이슈 `#756` P0의 DoD 두 번째 검증 명령 (코드블록 marker는 일부러 `` ```text `` — README의 첫 `` ```bash `` 블록은 위 snippet 단 하나여야 DoD awk 추출 + bash 실행이 self-reference 없이 통과한다):

```text
test -f .claude/plans/README.md && \
  awk '/^```bash/{f=1;next} /^```/{f=0;next} f' .claude/plans/README.md \
  | bash | grep -qE 'anki-study-mvp|noble-tumbling-dolphin'
```

이 검증은 hex 변종이 누적된 host의 main checkout (`<repo>/.claude/plans/`) 에서 수동 실행 가정이다. worktree 또는 fresh clone의 `.claude/plans/` 는 plan 누적이 없으므로 매칭 실패한다. PR/CI 자동 검증 대상이 아니다 — PR reviewer는 main checkout에서 한 번 수동 실행해 통과를 확인한다.
