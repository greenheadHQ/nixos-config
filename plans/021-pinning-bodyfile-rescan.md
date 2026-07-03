# Plan 021: pinning-guard가 `--body-file`/`-F body=@file` 파일 내용까지 스캔하게 한다

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 79530cec..HEAD -- modules/shared/programs/claude/files/hooks/pinning-guard.sh modules/shared/programs/codex/files/hooks/pinning-guard.sh modules/shared/programs/claude/files/lib/pinning-patterns.sh tests/test-codex-hook-fixtures.sh`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (PreToolUse fail-closed 경계를 만진다 — 과차단 시 durable write 전체가 막힘)
- **Depends on**: none
- **Category**: bug (guard coverage gap)
- **Planned at**: commit `79530cec`, 2026-07-03
- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/684

## Why this matters

pinning-guard는 커밋 메시지·PR/이슈 본문 같은 durable 텍스트에 휘발성 리뷰/세션
메타데이터(예: 임시 리뷰 ID)가 박제되는 것을 PreToolUse에서 차단한다. 그런데
Bash 분기는 **command 문자열만** 스캔하므로, `gh pr create --body-file /tmp/body.md`
처럼 본문을 파일로 우회 전달하면 파일 내용이 검사 없이 통과한다. 실제로 LLM이
긴 본문을 heredoc으로 임시 파일에 쓴 뒤 `--body-file`로 게시하는 패턴은 이
저장소의 일상 흐름이라, 이 구멍은 가드의 주 사용 경로에서 열려 있다.

## Current state

관련 파일과 역할:

- `modules/shared/programs/claude/files/hooks/pinning-guard.sh` — Claude Code
  PreToolUse 가드. Bash 분기 118–127행.
- `modules/shared/programs/codex/files/hooks/pinning-guard.sh` — Codex 변형.
  Bash 분기 71–80행. `apply_patch` 분기(121–142행)는 별도로 존재하며 이 plan의
  대상이 아니다.
- `modules/shared/programs/claude/files/lib/pinning-patterns.sh` — 패턴/스캔
  SSOT. 두 훅이 공유한다. 주요 함수: `pinning_should_check_path`(133행),
  `pinning_findings_text`(544행), `pinning_guard_findings_text_for_path`(713행).
- `tests/test-codex-hook-fixtures.sh` — Claude/Codex 훅 fixture 테스트 드라이버.

Claude 쪽 Bash 분기 현재 코드 (`modules/shared/programs/claude/files/hooks/pinning-guard.sh:118-127`):

```bash
  Bash)
    COMMAND_TEXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    [ -n "$COMMAND_TEXT" ] || exit 0
    _targeted_bash_command "$COMMAND_TEXT" || exit 0

    _scan_text_file "$COMMAND_TEXT" "$SCAN_DIR/new.txt"
    findings="$(pinning_findings_text "$SCAN_DIR/new.txt")"
    [ -n "$findings" ] || exit 0
    _deny "$TOOL_NAME" "durable shell command" "$findings"
    ;;
```

Codex 쪽 동일 구조 (`modules/shared/programs/codex/files/hooks/pinning-guard.sh:71-80`).
`_targeted_bash_command`는 양쪽 모두 `git commit`, `gh pr create|edit|comment|review`,
`gh issue create|edit|comment`, `gh api …(issues|pulls)…comments|reviews` 를 매치한다
(claude:49-58, codex:54-63).

저장소 관례:

- 두 훅은 로직을 최대한 `pinning-patterns.sh`(SSOT lib)에 두고 자신은 얇은
  어댑터로 유지한다 — 헤더 주석(양쪽 2–5행)이 이 계약을 명시한다. 새 파서도
  lib에 넣는다.
- fail-closed 정책: lib 로드 실패 시 deny. 새 코드도 "스캔해야 하는데 할 수
  없음 → deny"를 따른다.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 훅 fixture 테스트 | `bash tests/test-codex-hook-fixtures.sh` | exit 0, 전체 pass |
| shell 스크립트 테스트 | `bash tests/run-shell-script-tests.sh` | exit 0 |
| shellcheck | `shellcheck modules/shared/programs/claude/files/lib/pinning-patterns.sh modules/shared/programs/claude/files/hooks/pinning-guard.sh modules/shared/programs/codex/files/hooks/pinning-guard.sh` | 경고 0 (기존 수준 유지) |
| 통합 게이트 | `bash tests/run-all-tests.sh` | 끝 요약에서 FAILED 0 |

## Scope

**In scope** (수정 가능한 파일):

- `modules/shared/programs/claude/files/lib/pinning-patterns.sh` (파서 함수 추가)
- `modules/shared/programs/claude/files/hooks/pinning-guard.sh` (Bash 분기)
- `modules/shared/programs/codex/files/hooks/pinning-guard.sh` (Bash 분기)
- `tests/test-codex-hook-fixtures.sh` 및 그 fixture 디렉토리 (테스트 추가)

**Out of scope** (건드리지 말 것):

- `apply_patch` 분기(codex)와 Edit/Write/NotebookEdit 분기 — 이미 파일 내용을
  스캔한다.
- `_targeted_bash_command`의 명령 매치 목록 확장 — 별도 논의 사항.
- `pinning-alert.sh` (PostToolUse 경고 훅) — 이슈 #684의 대상은 hard-fail
  가드다. alert 쪽 동일 보강은 follow-up으로 남긴다.
- pinning 패턴(정규식) 자체의 변경.

## Git workflow

- Branch: `fix/684-pinning-bodyfile-rescan`
- Conventional commits (예: `fix(hooks): pinning-guard가 --body-file 파일 내용 재스캔 (#684)`)
- push/PR 생성은 운영자 지시 없이는 하지 않는다.

## Steps

### Step 1: lib에 파일 참조 인자 파서 추가

`modules/shared/programs/claude/files/lib/pinning-patterns.sh`에 함수
`pinning_extract_body_file_paths`를 추가한다. 입력: command 문자열(stdin이 아닌
`$1`). 출력: 줄 단위 파일 경로 목록. 매치 대상:

- `--body-file <path>` / `--body-file=<path>` (gh pr/issue 계열)
- `-F <path>` — 단, `gh api`가 아닌 `gh pr|issue` 문맥에서만 `--body-file`의
  단축으로 취급
- `gh api` 문맥의 `-F <field>=@<path>` / `--field <field>=@<path>` (@ 파일 확장)
- `git commit -F <path>` / `--file <path>` / `--file=<path>`

인용부호(single/double quote)로 감싼 경로는 인용부호를 벗겨 반환한다. 완전한
shell 파싱은 목표가 아니다 — 위 패턴의 보수적(과탐지 허용) 매치면 충분하다.
과탐지로 존재하지 않는 "경로"가 나오는 경우는 Step 2의 존재 검사에서 걸러진다.

**Verify**: `zsh -fc 'source modules/shared/programs/claude/files/lib/pinning-patterns.sh; pinning_extract_body_file_paths "gh pr create --title t --body-file /tmp/b.md"'` → `/tmp/b.md` 출력

### Step 2: 두 훅의 Bash 분기에서 파일 내용 스캔 추가

양쪽 pinning-guard.sh의 Bash 분기에서, 기존 command 문자열 스캔(유지) 뒤에:

1. `pinning_extract_body_file_paths "$COMMAND_TEXT"`로 경로 목록을 얻는다.
2. 각 경로에 대해: 파일이 존재하면 내용을 `$SCAN_DIR`의 스캔 파일로 복사 후
   `pinning_findings_text`로 스캔, findings가 있으면 `_deny "$TOOL_NAME"
   "<경로> (via --body-file)" "$findings"`.
3. **fail-closed**: 파일이 존재하는데 읽기 실패(권한 등)하면 deny. 파일이
   존재하지 않으면 통과(명령 자체가 어차피 실패한다).

두 훅의 diff가 대칭이 되도록 같은 구조로 작성한다.

**Verify**: `printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr create --body-file /tmp/pin-test.md"}}' | HOOK_RUNTIME_LIB=modules/shared/programs/claude/files/lib/hook-runtime.sh PINNING_PATTERNS_LIB=modules/shared/programs/claude/files/lib/pinning-patterns.sh bash modules/shared/programs/claude/files/hooks/pinning-guard.sh` — `/tmp/pin-test.md`에 pinning 위반 텍스트(기존 fixture에서 복사)를 넣은 상태에서 deny JSON 출력, 위반 없는 내용이면 출력 없이 exit 0

### Step 3: fixture 테스트 추가

`tests/test-codex-hook-fixtures.sh`의 기존 pinning Bash fixture를 패턴 삼아
다음 케이스를 Claude/Codex 양쪽에 추가한다:

1. `--body-file` 파일에 위반 내용 → deny
2. `--body-file` 파일이 깨끗 → allow
3. `gh api … -F body=@file` 파일에 위반 내용 → deny
4. `--body-file` 경로가 존재하지 않음 → allow
5. (회귀) command 문자열 자체에 위반 → 기존대로 deny

**Verify**: `bash tests/test-codex-hook-fixtures.sh` → exit 0, 신규 케이스 포함 전체 pass

### Step 4: 전체 게이트

**Verify**: `bash tests/run-all-tests.sh` → FAILED 0

## Test plan

- Step 3의 fixture 5종 × 2 runtime(Claude/Codex). 기존 fixture의 등록/기대값
  방식을 그대로 모방한다 (`tests/test-codex-hook-fixtures.sh` 내 기존 pinning
  케이스가 구조 패턴).
- 파서 단위 동작은 Step 1 verify로 확인 (별도 단위 테스트 파일 신설 금지 —
  이 repo의 훅 테스트는 fixture 드라이버로 수렴한다).

## Done criteria

- [ ] `bash tests/test-codex-hook-fixtures.sh` exit 0 (신규 케이스 포함)
- [ ] `bash tests/run-all-tests.sh` FAILED 0
- [ ] 양쪽 훅의 Bash 분기 diff가 구조적으로 대칭
- [ ] 파서는 `pinning-patterns.sh`에만 존재 (훅에 inline 파싱 없음)
- [ ] in-scope 밖 파일 수정 없음 (`git status`)
- [ ] `plans/README.md` status row 갱신

## STOP conditions

- "Current state"의 발췌와 실제 코드가 불일치 (drift).
- `_targeted_bash_command` 매치 목록을 바꿔야만 구현이 가능해 보이는 경우.
- fixture 드라이버의 등록 방식이 케이스 추가를 지원하지 않는 구조로 보이는 경우.
- Step 2 verify에서 deny/allow가 기대와 2회 이상 반대로 나오는 경우.

## Maintenance notes

- `_targeted_bash_command`에 새 명령(예: `gh release create`)을 추가하는 사람은
  그 명령의 파일 참조 플래그(`--notes-file` 등)를 파서에도 추가해야 한다 —
  리뷰에서 이 짝을 확인할 것.
- `pinning-alert.sh`(PostToolUse 경고)에는 같은 보강이 적용되지 않았다.
  follow-up 필요성이 보이면 새 이슈로.
