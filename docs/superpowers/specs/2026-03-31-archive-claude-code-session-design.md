# Claude Code 세션 아카이빙 설계

## 문제

Claude Code를 git worktree에서 실행한 후 worktree를 삭제하면, 세션 데이터(`~/.claude/projects/<encoded-wt-path>/`)는 디스크에 남아 있지만:

- `--continue`는 CWD 기반이라 삭제된 경로를 찾을 수 없음
- `--resume`은 UUID를 모르면 접근 불가
- `cleanupPeriodDays`에 의해 자동 삭제될 수 있음 (현재 99999일로 사실상 비활성)

결과: 대화 내역, 아이콘, 메모 등 귀중한 세션 컨텍스트가 사실상 유실.

### 관련 이슈

- anthropics/claude-code#20210 — worktree 삭제 시 세션 접근 불가
- anthropics/claude-code#34437 — worktree가 main repo와 프로젝트 디렉터리 공유 요청
- anthropics/claude-code#28314 — worktree cleanup 후 resume 실패

## 해결 방향

`/archive` 슬래시 커맨드로 세션 데이터를 `~/.claude/archive/`에 아카이빙.
원본 JSONL 복사(세션 재개용) + Markdown 변환(lossy 읽기 참조용).
SessionEnd 훅에 의한 자동 아카이빙으로 수동 작업 없이 보존.

## 아키텍처

```
사용자 ──/archive──▶ 슬래시 커맨드(스킬)
                         │
                         ▼
                   claude-archive.sh  (~/.claude/scripts/ 심링크)
                         │
                    ┌─────┴─────┐
                    ▼           ▼
              파일 수집      JSONL→MD 변환
                    │           │
                    └─────┬─────┘
                          ▼
                  ~/.claude/archive/
                  └── <project>/
                      └── <session-id>/
                          ├── <uuid>.jsonl
                          ├── <uuid>.md
                          ├── subagents/
                          ├── status-icons.json
                          ├── memo.md
                          └── meta.json
```

### 구성요소

| 구성요소 | 역할 | 위치 |
|---------|------|------|
| `claude-archive.sh` | 아카이빙 로직 전체 | `modules/shared/programs/claude/files/scripts/claude-archive.sh` |
| `/archive` 스킬 | 스크립트 호출 + 결과 표시 | `modules/shared/programs/claude/files/skills/archive/SKILL.md` |
| `auto-archive.sh` | SessionEnd 자동 아카이빙 훅 | `modules/shared/programs/claude/files/hooks/auto-archive.sh` |
| Nix 모듈 | 스크립트/훅 심링크 등록 | `modules/shared/programs/claude/default.nix` |
| recall (포크) | 아카이브 TUI 열람 | `github:greenheadHQ/recall` (GitHub flake input) |

## CLI 인터페이스

```bash
claude-archive                    # 현재 세션 아카이빙
claude-archive --session <id>     # 특정 세션 ID로 아카이빙
claude-archive --all              # 현재 CWD의 모든 세션
claude-archive --project          # 메인 레포 + 모든 worktree 세션
claude-archive --list             # 아카이브 목록 조회
claude-archive --restore <id>     # 원래 위치로 복원 (세션 재개용)
```

## 세션 ID 결정 로직

### --session <id> (직접 지정)

CWD를 인코딩하여 `~/.claude/projects/<encoded-cwd>/<id>.jsonl` 경로로 직접 아카이빙.
PID 파일 스캔 불필요. SessionEnd 자동 아카이빙에서 사용.

### 현재 세션 (기본)

`~/.claude/sessions/` 아래 PID 파일들을 스캔하여 현재 CWD와 일치하는 세션 ID를 찾음.
실패 시 가장 최근 수정된 JSONL을 fallback으로 선택 (경고 출력).

### --all (CWD 전체)

CWD를 인코딩하여 `~/.claude/projects/<encoded-cwd>/` 아래 모든 `.jsonl` 나열.

### --project (메인 + worktree)

`git rev-parse --git-common-dir`로 canonical root를 구한 뒤, 해당 경로와 모든 worktree 경로의 세션을 스캔.

## 수집 대상 파일

| 소스 | 대상 |
|------|------|
| `~/.claude/projects/<path>/<uuid>.jsonl` | `archive/<project>/<uuid>/<uuid>.jsonl` |
| `~/.claude/projects/<path>/<uuid>/subagents/` | `archive/<project>/<uuid>/subagents/` |
| `~/.claude/status-icons/<uuid>.json` | `archive/<project>/<uuid>/status-icons.json` |
| `~/.claude/memos/<uuid>.md` | `archive/<project>/<uuid>/memo.md` |

## JSONL → Markdown 변환

`jq` + 셸 스크립트로 직접 변환. 외부 도구 의존 없음.

### Artifact 계약

- **JSONL (`<uuid>.jsonl`)**: authoritative source. 완전한 대화 기록.
- **Markdown (`<uuid>.md`)**: **lossy 요약본**. 다음이 제외/잘림:
  - thinking 블록 (내부 추론)
  - tool_use input: 500자로 truncate
  - tool_result output: 300자로 truncate
  - system, file-history-snapshot 등 비user/assistant 이벤트
  - message가 null이거나 content가 빈 항목

### 출력 형태

```markdown
# Session: e9086b14-...
- **Branch**: feat/archive-claude-code-session-in-worktree
- **Date**: 2026-03-31
- **CWD**: /Users/glen/Workspace/nixos-config/.claude/worktrees/...

> **Note**: This Markdown is a lossy summary. ...

---

## User (13:50:13)
Claude Code를 worktree에서 실행했을 때 문제가 있어...

## Assistant (13:50:25)
brainstorming 스킬에 따라 진행합니다...
```

## meta.json 구조

```json
{
  "session_id": "e9086b14-...",
  "project": "nixos-config",
  "cwd": "/Users/glen/Workspace/nixos-config/.claude/worktrees/feat_...",
  "git_branch": "feat/archive-claude-code-session-in-worktree",
  "archived_at": "2026-03-31T13:55:00Z",
  "original_path": "~/.claude/projects/.../e9086b14.jsonl",
  "has_icons": true,
  "has_memo": true,
  "message_count": 42,
  "worktree": true
}
```

`message_count`는 raw JSONL의 user + assistant 엔트리 합계.
Markdown의 섹션 수와는 다를 수 있음 (lossy 변환으로 일부 항목이 제외되므로).

## --restore 복원 로직

1. `archive/<project>/<uuid>/<uuid>.jsonl` → `meta.json`의 `original_path`로 복사
2. `status-icons.json` → `~/.claude/status-icons/<uuid>.json`
3. `memo.md` → `~/.claude/memos/<uuid>.md`
4. `subagents/` → 원래 위치
5. 완료 후 `claude --resume <uuid>` 안내 출력

보안: allowlist 경로 검증 (`~/.claude/projects/`, `~/.claude/status-icons/`, `~/.claude/memos/` 하위만 허용).
symlink 대상 거부.

## SessionEnd 자동 아카이빙

`auto-archive.sh` 훅이 SessionEnd 이벤트에 등록되어 세션 종료 시 자동 아카이빙.

### 동작 원리

1. SessionEnd stdin JSON에서 `session_id`와 `cwd`를 읽음
2. `claude-archive.sh --session <session_id>`로 아카이빙 (PID 파일 의존성 없음)
3. `session_id` 미제공 시 CWD 기반 current 모드 fallback
4. CWD가 삭제된 워크트리인 경우 `$HOME`으로 fallback
5. 모든 에러를 무시 (SessionEnd는 비차단 훅)

### 정합성 논리

- `cleanupPeriodDays = 99999`: live JSONL 사실상 영구 보존
- `session-init-icons.sh` 30일 cleanup: live sidecar(icons, memos) 30일 후 삭제
- 자동 아카이빙이 세션 종료 시 sidecar를 아카이브에 복사하므로, 30일 후 live에서 삭제되어도 아카이브에 보존됨

## /archive 스킬

```yaml
---
name: archive
description: Archive Claude Code session data to ~/.claude/archive/
disable-model-invocation: true
---
```

- `$ARGUMENTS`에서 플래그 추출
- `claude-archive.sh` 실행
- 결과를 사용자에게 표시

Home Manager 심링크로 `~/.claude/skills/archive/SKILL.md`에 배치.

## Nix 심링크

`modules/shared/programs/claude/default.nix`의 `home.file`에서 `mkOutOfStoreSymlink`로 등록:

- `~/.claude/scripts/claude-archive.sh` → 스크립트 심링크
- `~/.claude/hooks/auto-archive.sh` → 훅 심링크
- `~/.claude/skills/archive/` → 스킬 심링크

## recall 포크: 아카이브 TUI 열람

### 레포

`github:greenheadHQ/recall` (upstream: `github:zippoxer/recall`)

### 수정 범위

1. `src/parser/mod.rs`의 `discover_session_files()`에 아카이브 디렉터리 스캔 추가
2. session_id 기반 중복 제거: 같은 UUID가 live와 archive에 모두 있으면 archive를 우선

### Nix 패키징

flake input으로 추가하여 빌드:

```nix
# flake.nix inputs
recall.url = "github:greenheadHQ/recall";

# modules/shared/programs/recall/default.nix
home.packages = [ inputs.recall.packages.${pkgs.system}.default ];
```

## 에러 처리

| 상황 | 동작 |
|------|------|
| CWD에 세션 없음 | "No sessions found for current directory" 출력 후 종료 |
| 세션 이미 아카이빙됨 | "Already archived: <uuid>" 스킵 |
| `~/.claude/archive/` 미존재 | 자동 생성 |
| JSONL 파싱 실패 | 원본 복사만 하고 Markdown 변환 스킵, 경고 출력 |
| `--restore` 시 원래 경로에 파일 존재 | "File already exists. Use --resume <uuid> directly." 안내 |
| `--project` 시 git 레포 아닌 경우 | "Not a git repository" 에러 |
| SessionEnd 자동 아카이빙 실패 | 조용히 무시 (비차단 훅) |

## 테스트 계획

1. worktree에서 `/archive` 실행 → 모든 파일이 `~/.claude/archive/`에 복사되는지 확인
2. `claude-archive --session <id>` → 특정 세션만 아카이빙
3. `claude-archive --list` → 아카이브 목록 정상 표시
4. worktree 삭제 후 `claude-archive --restore <uuid>` → 파일 복원 + `--resume` 가능
5. `claude-archive --all` → CWD의 모든 세션 아카이빙
6. `claude-archive --project` → 메인 + worktree 세션 전부 아카이빙
7. 이미 아카이빙된 세션 재실행 → 스킵 메시지
8. Markdown 변환 결과에 lossy 경고가 포함되는지 확인
9. recall TUI에서 아카이브 세션 표시 + 중복 없음 확인
10. 세션 종료 후 자동 아카이빙 확인
