# Git 설정

Git 관련 설정 및 도구 구성입니다.

## 목차

- [개발 도구](#개발-도구)
- [Git 설정](#git-설정)
- [Interactive Rebase 역순 표시](#interactive-rebase-역순-표시)
- [git-cleanup](#git-cleanup)
- [wt (Git Worktree 관리)](#wt-git-worktree-관리)
- [wt-cleanup (워크트리 정리)](#wt-cleanup-워크트리-정리)

---

`modules/shared/programs/git/default.nix`에서 관리됩니다.

## 개발 도구

| 도구      | 설명                                      |
| --------- | ----------------------------------------- |
| `git`     | 버전 관리                                 |
| `delta`   | Git diff 시각화 (구문 강조, side-by-side) |
| `lazygit` | Git TUI                                   |
| `gh`      | GitHub CLI                                |

## Git 설정

### Interactive Rebase 역순 표시

`git rebase -i` 실행 시 Fork GUI처럼 **최신 커밋이 위**, 오래된 커밋이 아래에 표시됩니다.

| CLI (기본)              | CLI (적용 후)           | Fork GUI                |
| ----------------------- | ----------------------- | ----------------------- |
| 오래된 → 최신 (위→아래) | 최신 → 오래된 (위→아래) | 최신 → 오래된 (위→아래) |

**구현 방식:**

- `sequence.editor`에 커스텀 스크립트 설정
- 편집 전: 커밋 라인을 역순 정렬하여 표시
- 편집 후: 원래 순서로 복원 (rebase 동작 정상 유지)
- `pkgs.writeShellScript`로 Nix store에서 스크립트 관리

**주의사항:**

- squash/fixup은 **아래쪽 커밋**이 **위쪽 커밋**으로 합쳐집니다 (Fork GUI와 동일)
- `git rebase --edit-todo`에서도 역순 표시가 적용됩니다

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

`modules/shared/programs/shell/default.nix`에서 관리됩니다.

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
6. 해당 디렉토리로 cd 이동 (`--stay` 미지정 시)
7. 에디터 열기 (macOS: cursor, NixOS: 경로 출력)

**브랜치 충돌 처리:**

- 브랜치가 이미 존재하면 선택 프롬프트 표시:
  - `[c]` 기존 브랜치로 워크트리 생성
  - `[n]` 기존 브랜치 삭제 후 새로 생성 (현재 HEAD 기준)
  - `[q]` 취소

**플랫폼별 동작:**

| 플랫폼 | 에디터 | 환경변수 |
|--------|--------|----------|
| macOS | cursor (기본) | `WT_EDITOR`로 변경 가능 |
| NixOS | 경로만 출력 | - |

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

**삭제 범위:**

| 대상 | 삭제 여부 |
|------|----------|
| 워크트리 | ✅ 삭제 |
| 로컬 브랜치 | ✅ 삭제 |
| 원격 브랜치 | ❌ 유지 |

> **참고**: dirty 워크트리 선택 시 `git diff --stat` 표시 후 확인 프롬프트가 나타납니다.
