# Git 커스텀 명령어

gdf, git-cleanup, wt, wt-cleanup 등 커스텀 명령어 사용법입니다.

## 목차

- [gdf (Git Diff → fzf → Neovim)](#gdf-git-diff--fzf--neovim)
- [git-cleanup](#git-cleanup)
- [wt (Git Worktree 관리)](#wt-git-worktree-관리)
- [wt-cleanup (워크트리 정리)](#wt-cleanup-워크트리-정리)

---

## gdf (Git Diff → fzf → Neovim)

`modules/shared/scripts/git-diff-fzf-functions.sh`에서 관리됩니다.
(`shell/default.nix`에서 `~/.local/lib/git-diff-fzf-functions.sh`로 source하여 로딩)

git diff 변경 파일을 fzf로 선택하여 nvim으로 여는 함수입니다. preview에 delta 렌더링이 적용됩니다.

**사용법:**

```bash
gdf              # 워킹 트리 변경 파일
gdf --cached     # 스테이징된 파일
gdf HEAD~3       # 최근 3커밋 변경 파일
```

**동작 흐름:**

1. `git diff --name-only`로 변경 파일 목록 수집
2. fzf에서 파일 선택 (TAB으로 다중 선택 가능)
3. preview에 delta 렌더링된 diff 표시
4. Enter로 선택된 파일을 nvim으로 열기

**fzf preview delta 설정:**

| 옵션 | 설명 |
|------|------|
| `--paging=never` | fzf가 자체 스크롤 처리 |
| `--width=$FZF_PREVIEW_COLUMNS` | preview 너비에 맞춤 |
| side-by-side 미적용 | preview 창이 좁아서 부적합 |

### gdl (Git Diff Last)

`gdf`를 래핑하여 직전 커밋 파일을 빠르게 선택합니다.

```bash
gdl        # 직전 1커밋 변경 파일
gdl 3      # 최근 3커밋 변경 파일
```

---

## git-cleanup

`scripts/git-cleanup.sh`에서 관리됩니다.

더 이상 사용되지 않는 로컬 브랜치를 식별하고 정리하는 스크립트입니다. `git cleanup` 또는 `git-cleanup` 명령어로 실행합니다.

**삭제 기준:**

| 상태 | 아이콘 | 설명 | 삭제 방식 |
|------|--------|------|----------|
| gone | O | 원격에서 삭제된 브랜치 (PR 머지 후 삭제됨) | `-D` (강제) |
| stale | 경고 | 30일 이상 된 로컬 전용 브랜치 | `-D` (강제) |
| protected | 잠금 | 보호 브랜치 (main, master, develop, stage) | 삭제 불가 |
| current | 현재 | 현재 체크아웃된 브랜치 | 삭제 불가 |

**사용법:**

```bash
# 삭제 대상 미리보기 (권장)
git cleanup --dry-run

# 실제 정리
git cleanup

# 도움말
git cleanup --help
```

**메뉴 옵션:**

| 옵션 | 설명 |
|------|------|
| `[a]` | gone 상태 전체 삭제 |
| `[b]` | stale 상태 전체 삭제 |
| `[s]` | 하나씩 선택하여 삭제 (Y/n/q) |
| `[q]` | 취소 |

**출력 예시:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Git Branch Cleanup
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

── gone (3개) ──
  O [gone] feat/login (origin/feat/login)
  O [gone] fix/bug-123 (origin/fix/bug-123)
  O [gone] JIRA-456 (origin/JIRA-456)

── stale (2개) ──
  경고 [stale] experiment/test (45일 경과)
  경고 [stale] old-feature (120일 경과)

── 보호됨 ──
  잠금 main
  현재 develop (현재)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**동작 흐름:**

1. `git fetch --prune` 자동 실행 (원격 정보 동기화)
2. 브랜치 목록 수집 및 분류
3. 삭제 대상 표시
4. 사용자 선택에 따라 삭제 진행

> **참고**: 네트워크 오류 시에도 로컬 정보로 계속 진행합니다.

## wt (Git Worktree 관리)

`modules/shared/scripts/git-worktree-functions.sh`에서 관리됩니다.
(`shell/default.nix`에서 `~/.local/lib/git-worktree-functions.sh`로 source하여 로딩)

Git worktree를 `.wt/` 디렉토리에 생성하고 관리하는 함수입니다.

**사용법:**

```bash
wt <브랜치명>           # 워크트리 생성 + cd 이동 + 에디터 열기
wt -s <브랜치명>        # 워크트리 생성만 (현재 위치에 stay)
wt --stay <브랜치명>    # 동일 (긴 형식)
```

**옵션:**

| 옵션 | 설명 |
|------|------|
| `-s`, `--stay` | 워크트리 생성 후 현재 디렉토리에 머무름 |

**동작 흐름:**

1. Git 저장소 확인
2. 브랜치가 이미 워크트리에서 사용 중인지 확인
3. 디렉토리명 생성 (슬래시 → 언더스코어: `feature/login` → `feature_login`)
4. 브랜치 존재 여부 확인 (로컬/원격)
5. 워크트리 생성
6. `.wt-parent` 파일 생성 (부모 브랜치 기록)
7. 해당 디렉토리로 cd 이동 (`--stay` 미지정 시)
8. 에디터 열기 (macOS: cursor, NixOS: 경로 출력)

### Known Regression (2026-02-27)

`wt` 실행 직후 아래 untracked가 생기면 중첩 복사 회귀다:

```bash
?? .agents/.agents/
?? .claude/.claude/
```

원인(회귀 당시):
- `git worktree add`로 이미 생성된 `.claude`, `.agents` 위에
- `cp -R "$source_root/$_dir" "$worktree_dir/$_dir"`를 다시 수행해
- `.claude/.claude`, `.agents/.agents`가 중첩 생성됨

특히 source worktree가 이미 중첩 상태이면, 다음 `wt`에서 `.claude/.claude/.claude`처럼 재귀적으로 악화될 수 있다.

빠른 진단:

```bash
git status --short
find .claude -maxdepth 3 -type d -name .claude
find .agents -maxdepth 3 -type d -name .agents
```

임시 정리:

```bash
rm -rf .claude/.claude .agents/.agents
```

영구 수정 원칙:
- 대상 디렉토리가 이미 존재하면 재복사를 건너뛴다.
- `cp -R source/. target/` 같은 병합 복사로 바꾸지 않는다 (세션 부산물/중첩 오염 전파 위험).

자동 회귀 방지:
- `wt()` 내부에 중첩 디렉토리 감지 가드가 있다 (`.claude/.claude`, `.agents/.agents`, `.codex/.codex` 감지 시 즉시 실패).
- `tests/run-wt-regression.sh`가 회귀 테스트를 수행한다.
- `lefthook` pre-commit에서 `modules/shared/scripts/git-worktree-functions.sh` 변경 시 자동 실행된다.

**브랜치 충돌 처리:**

- 브랜치가 이미 존재하면 선택 프롬프트 표시:
  - `[c]` 기존 브랜치로 워크트리 생성
  - `[n]` 기존 브랜치 삭제 후 새로 생성 (현재 HEAD 기준)
  - `[q]` 취소

**삭제 시 안전 체크:**

`[n]` 선택 시 작업 손실을 방지하기 위해 다음을 체크합니다:

| 체크 항목 | 비교 기준 | 메시지 |
|-----------|----------|--------|
| 커밋 체크 | `.wt-parent` (부모 브랜치) | `'sprint/glen' 이후 2개의 커밋이 있습니다` |
| 커밋 체크 (fallback) | upstream | `'origin/PROJ-123' 이후 push되지 않은 2개의 커밋이 있습니다` |
| dirty 체크 | - | `커밋되지 않은 변경사항이 있습니다` |

경고가 표시되면 `정말 삭제하시겠습니까? [y/N]` 확인 프롬프트가 나타납니다.

**.wt-parent 파일:**

worktree 생성 시 현재 브랜치를 `.wt-parent` 파일에 기록합니다.

```bash
# 예: sprint/glen에서 wt PROJ-12345 실행
cat .wt/PROJ-12345/.wt-parent
# 출력: sprint/glen
```

이 파일은 global gitignore에 등록되어 있어 `git status`에 표시되지 않습니다.

**플랫폼별 동작:**

| 플랫폼 | 에디터 | 환경변수 |
|--------|--------|----------|
| macOS | cursor (기본) | `WT_EDITOR`로 변경 가능 |
| NixOS | 경로만 출력 | - |

**nrs worktree 지원:**

worktree에서 `nrs`/`nrp` 실행 시 자동으로 worktree의 flake를 빌드합니다 (`detect_worktree()`). 심링크 타깃(`nixosConfigPath`)은 메인 레포로 고정되며, 기존 `.wt/*/modules/shared/programs/claude/files/*` stale 심링크(`~/.claude/skills`, `~/.claude/hooks`, `~/.claude/*.json`, `~/.claude/*.md`)는 activation에서 자동 정리되므로 별도 `nrs` 재실행은 필요하지 않습니다.

## wt-cleanup (워크트리 정리)

`.wt/` 디렉토리 내의 워크트리를 정리하는 함수입니다.

**사용법:**

```bash
wt-cleanup
```

**PR 상태 아이콘:**

| 아이콘 | 상태 | 설명 |
|--------|------|------|
| ✅ | MERGED | 삭제 권장 |
| 🔵 | OPEN | PR 진행 중 |
| 🚫 | CLOSED | 머지 없이 닫힘 |
| 📵 | OFFLINE | 네트워크 불가 |
| ⚪ | NONE | PR 없음 |
| 💾 | DIRTY | 커밋 안 된 변경사항 있음 |

**동작 흐름:**

1. `.wt/` 디렉토리 내 워크트리 목록 수집
2. 각 워크트리의 dirty 상태 확인
3. gh CLI로 PR 상태 병렬 조회
4. fzf 다중 선택 UI 표시 (없으면 번호 입력)
5. 선택된 워크트리 삭제 (`git worktree remove --force`)
6. 로컬 브랜치 삭제 (`git branch -D`)

**삭제 시 안전 체크:**

wt와 동일하게 커밋 체크 + dirty 체크를 수행합니다:

| 체크 항목 | 비교 기준 | 메시지 |
|-----------|----------|--------|
| 커밋 체크 | `.wt-parent` (부모 브랜치) | `'PROJ-123' (branch): 'sprint/glen' 이후 2개의 커밋이 있습니다` |
| 커밋 체크 (fallback) | upstream | `'PROJ-123' (branch): 'origin/PROJ-123' 이후 push되지 않은 2개의 커밋이 있습니다` |
| dirty 체크 | - | `'PROJ-123' (branch)에 커밋되지 않은 변경사항이 있습니다` |

경고가 표시되면 `삭제할까요? [y/N]` 확인 프롬프트가 나타납니다.

**삭제 범위:**

| 대상 | 삭제 여부 |
|------|----------|
| 워크트리 | 삭제 |
| 로컬 브랜치 | 삭제 |
| 원격 브랜치 | 유지 |
