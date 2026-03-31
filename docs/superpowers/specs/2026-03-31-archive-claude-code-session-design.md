# Claude Code 세션 아카이빙 설계

## 문제

Claude Code를 git worktree에서 실행한 후 worktree를 삭제하면, 세션 데이터(`~/.claude/projects/<encoded-wt-path>/`)는 디스크에 남아 있지만:

- `--continue`는 CWD 기반이라 삭제된 경로를 찾을 수 없음
- `--resume`은 UUID를 모르면 접근 불가
- 30일 후 `cleanupPeriodDays`에 의해 자동 삭제됨

결과: 대화 내역, 아이콘, 메모 등 귀중한 세션 컨텍스트가 사실상 유실.

### 관련 이슈

- anthropics/claude-code#20210 — worktree 삭제 시 세션 접근 불가
- anthropics/claude-code#34437 — worktree가 main repo와 프로젝트 디렉터리 공유 요청
- anthropics/claude-code#28314 — worktree cleanup 후 resume 실패

## 해결 방향

`/archive` 슬래시 커맨드로 세션 데이터를 `~/.claude/archive/`에 수동 아카이빙. 원본 JSONL 복사(세션 재개용) + Markdown 변환(읽기 참조용).

## 아키텍처

```
사용자 ──/archive──▶ 슬래시 커맨드(스킬)
                         │
                         ▼
                   claude-archive.sh  (writeShellApplication)
                         │
                    ┌─────┴─────┐
                    ▼           ▼
              파일 수집      JSONL→MD 변환
                    │           │
                    └─────┬─────┘
                          ▼
                  ~/.claude/archive/
                  ├── index.json
                  └── <project>/
                      └── <session-id>/
                          ├── session.jsonl
                          ├── session.md
                          ├── subagents/
                          ├── status-icons.json
                          ├── memo.md
                          └── meta.json
```

### 구성요소

| 구성요소 | 역할 | 위치 |
|---------|------|------|
| `claude-archive.sh` | 아카이빙 로직 전체 | `modules/shared/programs/claude/scripts/claude-archive.sh` |
| `/archive` 스킬 | 스크립트 호출 + 결과 표시 | `modules/shared/programs/claude/commands/archive.md` |
| Nix 모듈 | 스크립트 패키징 + PATH 등록 | `modules/shared/programs/claude/default.nix` |
| recall (포크) | 아카이브 TUI 열람 | `github:greenheadHQ/recall` (flake input) |

## CLI 인터페이스

```bash
claude-archive                    # 현재 세션 아카이빙
claude-archive --all              # 현재 CWD의 모든 세션
claude-archive --project          # 메인 레포 + 모든 worktree 세션
claude-archive --list             # 아카이브 목록 조회
claude-archive --restore <id>     # 원래 위치로 복원 (세션 재개용)
claude-archive --browse           # recall TUI로 아카이브 열람
```

## 세션 ID 결정 로직

### 현재 세션 (기본)

`~/.claude/sessions/` 아래 PID 파일들을 스캔하여 현재 CWD와 일치하는 세션 ID를 찾음.

```bash
for pid_file in ~/.claude/sessions/*.json; do
  cwd=$(jq -r '.cwd' "$pid_file")
  if [ "$cwd" = "$PWD" ]; then
    session_id=$(jq -r '.sessionId' "$pid_file")
  fi
done
```

### --all (CWD 전체)

CWD를 인코딩하여 `~/.claude/projects/<encoded-cwd>/` 아래 모든 `.jsonl` 나열.

인코딩 규칙: 절대 경로의 `/`, `.`, `_`를 `-`로 치환.

### --project (메인 + worktree)

`git rev-parse --show-toplevel`로 메인 레포 경로를 구한 뒤, `~/.claude/projects/` 내에서 해당 경로를 prefix로 가진 모든 디렉터리 스캔.

## 수집 대상 파일

| 소스 | 대상 |
|------|------|
| `~/.claude/projects/<path>/<uuid>.jsonl` | `archive/<project>/<uuid>/session.jsonl` |
| `~/.claude/projects/<path>/<uuid>/subagents/` | `archive/<project>/<uuid>/subagents/` |
| `~/.claude/status-icons/<uuid>.json` | `archive/<project>/<uuid>/status-icons.json` |
| `~/.claude/memos/<uuid>.md` | `archive/<project>/<uuid>/memo.md` |
| `~/.claude/projects/<path>/<uuid>/*.md` | `archive/<project>/<uuid>/memory/` |
| `~/.claude/projects/<path>/.statusline-plan-<uuid>` | `archive/<project>/<uuid>/statusline-plan` |

## JSONL → Markdown 변환

`jq` + 셸 스크립트로 직접 변환. 외부 도구 의존 없음.

### 출력 형태

```markdown
# Session: e9086b14-...
- **Branch**: feat/archive-claude-code-session-in-worktree
- **Date**: 2026-03-31
- **CWD**: /Users/glen/Workspace/nixos-config/.claude/worktrees/...

---

## User (13:50:13)
Claude Code를 worktree에서 실행했을 때 문제가 있어...

## Assistant (13:50:25)
brainstorming 스킬에 따라 진행합니다...

## Tool: Bash (13:50:26)
`ls -la ~/.claude/`
```

변환 규칙:
- `type` 필드(`user`, `assistant`, `system`)로 섹션 구분
- `tool_use`는 도구명과 입력을 요약 표시
- `thinking` 블록은 제외 (토큰 절약)
- 타임스탬프는 로컬 시간으로 변환

## meta.json 구조

```json
{
  "sessionId": "e9086b14-...",
  "project": "nixos-config",
  "cwd": "/Users/glen/Workspace/nixos-config/.claude/worktrees/feat_...",
  "gitBranch": "feat/archive-claude-code-session-in-worktree",
  "archivedAt": "2026-03-31T13:55:00Z",
  "originalPath": "~/.claude/projects/-Users-glen-Workspace-nixos-config--claude-worktrees-.../e9086b14.jsonl",
  "hasIcons": true,
  "hasMemo": true,
  "messageCount": 42,
  "worktree": true
}
```

## --restore 복원 로직

1. `archive/<project>/<uuid>/session.jsonl` → `meta.json`의 `originalPath`로 복사
2. `status-icons.json` → `~/.claude/status-icons/<uuid>.json`
3. `memo.md` → `~/.claude/memos/<uuid>.md`
4. `subagents/` → 원래 위치
5. 완료 후 `claude --resume <uuid>` 안내 출력

## /archive 스킬

```yaml
---
name: archive
description: Archive Claude Code session data (conversation, icons, memos) to ~/.claude/archive/
context: fork
disable-model-invocation: true
---
```

- `$ARGUMENTS`에서 플래그 추출
- `claude-archive.sh` 실행
- 결과를 사용자에게 표시

Home Manager 심링크로 `~/.claude/commands/archive.md`에 배치.

## Nix 패키징

```nix
claude-archive = pkgs.writeShellApplication {
  name = "claude-archive";
  runtimeInputs = with pkgs; [ jq coreutils findutils git ];
  text = builtins.readFile ./scripts/claude-archive.sh;
};
```

`home.packages`에 추가하여 PATH 등록.

위치: `modules/shared/programs/claude/default.nix` 기존 파일에 추가.

## index.json 관리

전체 아카이브 인덱스. `--list`에서 사용.

```json
[
  {
    "sessionId": "e9086b14-...",
    "project": "nixos-config",
    "gitBranch": "feat/archive-...",
    "archivedAt": "2026-03-31T13:55:00Z",
    "worktree": true,
    "messageCount": 42
  }
]
```

아카이빙 시 `jq`로 append, `--restore` 시 해당 항목 제거.

## recall 포크: 아카이브 TUI 열람

### 레포

`github:greenheadHQ/recall` (upstream: `github:zippoxer/recall`)

### 수정 범위

`src/parser/mod.rs`의 `discover_session_files()`에 아카이브 디렉터리 스캔 추가:

```rust
// ~/.claude/archive/**/*.jsonl (아카이브된 세션)
let archive_dir = home.join(".claude/archive");
if archive_dir.exists() {
    for entry in walkdir::WalkDir::new(&archive_dir)
        .into_iter()
        .flatten()
    {
        let path = entry.path();
        if path.extension().map(|e| e == "jsonl").unwrap_or(false) {
            if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                if name.starts_with("agent-") {
                    continue;
                }
            }
            files.push(path.to_path_buf());
        }
    }
}
```

이것만으로 recall TUI에서 아카이브된 세션이 라이브 세션과 함께 표시됨.

### Nix 패키징

flake input으로 추가하여 `naersk`로 빌드:

```nix
# flake.nix inputs
recall.url = "github:greenheadHQ/recall";

# modules/shared/programs/recall/default.nix
home.packages = [ inputs.recall.packages.${pkgs.system}.default ];
```

### --browse 동작

`claude-archive --browse`는 단순히 `recall`을 실행. recall이 `~/.claude/projects/` + `~/.claude/archive/` 둘 다 스캔하므로 라이브 + 아카이브 통합 뷰 제공.

## 에러 처리

| 상황 | 동작 |
|------|------|
| CWD에 세션 없음 | "No sessions found for current directory" 출력 후 종료 |
| 세션 이미 아카이빙됨 | "Already archived: <uuid>" 스킵 |
| `~/.claude/archive/` 미존재 | 자동 생성 |
| JSONL 파싱 실패 | 원본 복사만 하고 Markdown 변환 스킵, 경고 출력 |
| `--restore` 시 원래 경로에 파일 존재 | "File already exists. Use --resume <uuid> directly." 안내 |
| `--project` 시 git 레포 아닌 경우 | "Not a git repository" 에러 |

## 테스트 계획

1. worktree에서 `/archive` 실행 → 모든 파일이 `~/.claude/archive/`에 복사되는지 확인
2. `claude-archive --list` → 아카이브 목록 정상 표시
3. worktree 삭제 후 `claude-archive --restore <uuid>` → 파일 복원 + `--resume` 가능
4. `claude-archive --all` → CWD의 모든 세션 아카이빙
5. `claude-archive --project` → 메인 + worktree 세션 전부 아카이빙
6. 이미 아카이빙된 세션 재실행 → 스킵 메시지
7. Markdown 변환 결과가 읽기 쉬운지 확인
8. `claude-archive --browse` → recall TUI에서 아카이브 세션 표시
9. recall TUI에서 아카이브 세션 검색 + 미리보기 동작 확인
