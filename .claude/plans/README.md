# `.claude/plans/` 디렉토리 정책

본 디렉토리에는 Claude Code harness의 plan-mode runtime이 떨어뜨리는 **transient plan buffer** 가 누적된다. 이 디렉토리에서 tracked 인 파일은 본 README 하나뿐이고 (`.gitignore` 의 `!.claude/plans/README.md` 예외), 나머지 `.md` 는 이름 형태와 무관하게 전부 untracked runtime buffer다.

과거에는 `plan-with-questions` 스킬이 이 디렉토리에 SSOT plan 파일을 만들었으나 그 스킬은 #810·#812 로 완전 제거됐다 (커밋 `34733592`). **현재 이 디렉토리에 SSOT plan을 만드는 주체는 없다** — 지속 참조가 필요한 계획은 tracked 인 `plans/` 나 이슈 본문에 둔다. 여기 남은 buffer를 SSOT plan으로 승격하지 않는다.

연관 이슈: #756 (P0 — 본 README), #756 P1 (transient buffer GC 정책/훅).

## Transient buffer 식별 기준

untracked `.md` 는 모두 runtime buffer로 간주한다. 파일명 형태는 harness 세대에 따라 다르며, 아래 표의 8hex 형태만 GC 대상이다 (`plans-gc.sh` 가 이 절을 정본으로 인용한다).

| 파일명 형태 | 예 | GC 대상 |
|---|---|---|
| `<prefix>-<8hex>.md` | `foo-1a2b3c4d.md` | O — `plans-gc.sh` 의 `-[0-9a-f]{8}\.md$` 에 매칭 |
| 3단어 랜덤 slug | `calm-pondering-llama.md` | X — 정규식 미매칭이라 잔존 |
| 날짜·토픽 수동 파일 | `2026-08-15-run-da-overhaul.md` | X |
| `-agent-<가변길이 hex>.md` | `...-agent-a6bbadcd76d351e67.md` | X — 끝 8자 앞이 `-` 가 아니라 미매칭 (과거 sub-agent 산출물) |

판정 기준은 prefix가 아니라 **꼬리 형태**다 — hex 길이가 우연히 8이면 `-agent-` 계열도 매칭된다 (`foo-agent-1a2b3c4d.md`).

실측 (2026-09-05, main checkout): 8hex buffer 0건, hex 없는 `.md` 54건. 재확인은 아래 snippet(8hex 집계)과 `find .claude/plans -maxdepth 1 -type f -name '*.md' ! -name README.md | wc -l` (buffer 전체) 를 함께 본다. 즉 **현재 누적분은 GC 대상이 아니다.** 8hex 기준은 #756 P1 도입 시점 harness의 이름 형태를 반영한 것이고, 이후 harness가 3단어 slug로 바뀌면서 기준과 실제 누적분이 어긋났다. GC 규칙 확대는 `plans-gc.sh` 동작 변경이므로 문서가 아니라 별도 이슈에서 다룬다.

## GC 정책

`modules/shared/programs/claude/files/hooks/plans-gc.sh` (SessionEnd hook, #756 P1) 가 정리 주체다. 삭제 조건은 **untracked + 8hex 형태 + mtime 7일 초과** 세 개의 논리곱이며, tracked 파일 (README.md) 과 최근 buffer는 보존한다. 임계값·정규식의 정본은 스크립트 상단 상수(`GC_AGE_DAYS`, `HEX_RE`)다.

## Prefix별 hex 변종 집계 snippet

다음 one-liner를 repo root에서 실행하면 GC 대상 형태(8hex) 의 prefix별 누적 수를 내림차순으로 본다. GC가 도는 환경에서는 출력이 비는 것이 정상이며, 출력이 있으면 아직 mtime 7일 임계를 넘지 않았거나 SessionEnd hook이 돌지 않은 buffer가 남아 있다는 뜻이다.

```bash
find "${1:-.claude/plans}" -maxdepth 1 -type f \
  -name '*-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].md' \
  | sed -E 's|^.*/||; s/-[0-9a-f]{8}\.md$//' \
  | sort | uniq -c | sort -rn
```

다른 머신 또는 다른 디렉토리를 보려면 첫 인자로 경로를 넘긴다. hex suffix 파일만 입력으로 삼으므로 hex 없는 buffer는 집계에 포함되지 않는다 (의도 — 그쪽은 GC 대상이 아니다). GNU/BSD find 공통 형태로 macOS 와 NixOS 양쪽에서 동작한다.
