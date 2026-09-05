# `.claude/plans/` 디렉토리 정책

본 디렉토리에는 Claude Code harness의 plan-mode runtime이 떨어뜨리는 **transient plan buffer** 가 누적된다. 이 디렉토리에서 tracked 인 파일은 본 README 하나뿐이고 (`.gitignore` 의 `!.claude/plans/README.md` 예외), 나머지 `.md` 는 전부 untracked다. 대부분은 runtime buffer지만, 과거에 사람이 손으로 두거나 스킬이 만든 문서도 같은 이름 공간에 섞여 있어 **이름만으로는 둘을 완전히 구분할 수 없다** — GC 판정이 이름 하나에 의존하지 않는 이유다.

과거에는 `plan-with-questions` 스킬이 이 디렉토리에 SSOT plan 파일을 만들었으나 그 스킬은 #810·#812 로 완전 제거됐다 (커밋 `34733592`). **현재 이 디렉토리에 SSOT plan을 만드는 주체는 없다** — 지속 참조가 필요한 계획은 tracked 인 `plans/` 나 이슈 본문에 둔다. 여기 남은 buffer를 SSOT plan으로 승격하지 않는다.

연관 이슈: #756 (P0 — 본 README), #756 P1 (transient buffer GC 정책/훅).

## Transient buffer 식별 기준

파일명 형태는 harness 세대에 따라 다르며, 아래 표의 두 형태가 GC 대상이다 (`plans-gc.sh` 가 이 절을 정본으로 인용한다). 다만 이름 판정만으로는 사람이 쓴 문서를 걸러내지 못하므로, 본문에 SSOT 마커 (`## Document Status` 로 시작하는 줄) 가 있으면 이름이 무엇이든 보존한다.

| 파일명 형태 | 예 | GC 대상 |
|---|---|---|
| `<prefix>-<8hex>.md` | `foo-1a2b3c4d.md` | O — `plans-gc.sh` 의 `-[0-9a-f]{8}\.md$` 에 매칭 |
| 가운데가 `-ing` 로 끝나는 3단어 slug | `calm-pondering-llama.md` | O — `^[a-z]+-[a-z]+ing-[a-z]+\.md$` 에 매칭 |
| 위 두 형태 + 본문에 SSOT 마커 | `wise-kindling-eich.md` | X — 마커 보유 파일은 이름 무관 보존 |
| 가운데가 `-ing` 가 아닌 3단어 | `codex-pushover-credentials.md` | X — slug 정규식 미매칭 |
| 날짜·토픽 수동 파일 | `2026-08-15-run-da-overhaul.md` | X — 숫자로 시작해 slug 정규식 미매칭 |
| `-agent-<가변길이 hex>.md` | `...-agent-a6bbadcd76d351e67.md` | X — 끝 8자 앞이 `-` 가 아니라 미매칭 (과거 sub-agent 산출물) |

hex 형태의 판정 기준은 prefix가 아니라 **꼬리 형태**다 — hex 길이가 우연히 8이면 `-agent-` 계열도 매칭된다 (`foo-agent-1a2b3c4d.md`). slug 형태는 반대로 파일명 **전체**를 앵커로 고정한다.

`-ing` 한정은 관측에 근거한 휴리스틱이지 harness의 보증이 아니다. 2026-09-06 main checkout 실측에서 slug 형태 44건이 모두 `<형용사>-<동사>ing-<명사>` 였고, 제약을 "3단어면 buffer" 로 넓히면 `codex-pushover-credentials.md` 같은 사람 문서까지 삼킨다. **잔존 위험**: 이 저장소 어휘에는 `hosting`·`managing`·`analyzing` 처럼 gerund가 자연스럽게 들어가므로, `nix-building-cache.md` 같은 사람 문서를 SSOT 마커 없이 두면 GC 대상이 된다. 그래서 hook은 삭제 대신 `.claude/plans/.trash/<YYYY-MM-DD>/` 로 옮겨 30일간 복구 가능하게 둔다.

실측 (2026-09-06, main checkout): 8hex buffer 0건, slug 형태 44건 (그중 SSOT 마커 보유 2건은 보존), 날짜·수동 문서 11건. 재확인은 아래 snippet(8hex 집계)과 `find .claude/plans -maxdepth 1 -type f -name '*.md' ! -name README.md | wc -l` (buffer 전체) 를 함께 본다.

## GC 정책

`modules/shared/programs/claude/files/hooks/plans-gc.sh` (SessionEnd hook, #756 P1) 가 정리 주체다. 회수 조건은 **untracked + (8hex 형태 또는 `-ing` 3단어 slug 형태) + SSOT 마커 없음 + mtime 7일 초과** 의 논리곱이며, tracked 파일 (README.md) 과 최근 buffer는 보존한다. 임계값·정규식의 정본은 스크립트 상단 상수(`GC_AGE_DAYS`, `TRASH_KEEP_DAYS`, `HEX_RE`, `SLUG_RE`, `SSOT_MARKER_RE`)다.

회수는 `rm` 이 아니라 `.claude/plans/.trash/<YYYY-MM-DD>/` 로의 이동이다. 이 디렉토리는 untracked라 git으로 되돌릴 수 없으므로, 이름 휴리스틱의 오판을 사람이 알아채고 되살릴 시간을 남긴다. trash의 날짜 디렉토리는 `TRASH_KEEP_DAYS` (30일) 를 넘기면 다음 SessionEnd에서 만료된다. 잘못 회수된 문서는 그 안에서 원래 이름 그대로 찾아 되돌린다.

hook은 `~/.claude/hooks/plans-gc.sh` → nix store → 이 저장소 작업 트리 파일로 이어지는 out-of-store symlink다. 즉 **소스 파일이 바뀌는 순간(예: main pull) 부터 다음 SessionEnd에 새 규칙이 적용된다** — `nrs` 재빌드는 필요하지 않다.

## Prefix별 hex 변종 집계 snippet

다음 one-liner를 repo root에서 실행하면 8hex 형태의 prefix별 누적 수를 내림차순으로 본다. GC가 도는 환경에서는 출력이 비는 것이 정상이며, 출력이 있으면 아직 mtime 7일 임계를 넘지 않았거나 SessionEnd hook이 돌지 않은 buffer가 남아 있다는 뜻이다. slug 형태는 hex suffix가 없어 이 집계에 잡히지 않는다 (의도) — slug 누적분은 위 실측 명령으로 본다.

```bash
find "${1:-.claude/plans}" -maxdepth 1 -type f \
  -name '*-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].md' \
  | sed -E 's|^.*/||; s/-[0-9a-f]{8}\.md$//' \
  | sort | uniq -c | sort -rn
```

다른 머신 또는 다른 디렉토리를 보려면 첫 인자로 경로를 넘긴다. hex suffix 파일만 입력으로 삼으므로 hex 없는 buffer는 집계에 포함되지 않는다. GNU/BSD find 공통 형태로 macOS 와 NixOS 양쪽에서 동작한다.
