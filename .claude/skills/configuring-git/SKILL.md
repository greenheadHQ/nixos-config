---
name: configuring-git
description: |
  This skill should be used when the user configures Git with Home Manager,
  sets up delta, rerere, lazygit delta pager, or encounters gitconfig conflicts.
  Covers custom aliases, git-cleanup scripts, rebase reverse display, lazygit config.
---

# Git 설정

Git, delta diff, lazygit, rerere 등 Git 관련 설정 가이드입니다.

## 빠른 참조

### 주요 기능

| 기능 | 설명 |
|------|------|
| delta | Git diff를 구문 강조로 표시 |
| lazygit (`lg`) | Git TUI (delta pager 통합) |
| rerere | 충돌 해결 패턴 기록/재사용 |
| rebase 역순 | Interactive rebase에서 최신 커밋이 위로 |
| git-cleanup | 오래된/삭제된 브랜치 정리 |
| wt | Git worktree 생성 및 관리 (삭제 시 커밋 체크) |
| wt-cleanup | 워크트리 정리 (PR 상태 + 커밋 체크) |

### delta 설정 확인

```bash
# delta가 설치되어 있는지 확인
which delta

# Git에서 delta 사용 중인지 확인
git config --get core.pager
```

### delta 옵션 (feature 구조)

기본 옵션은 `programs.delta.options`에서, 도구별 오버라이드는 feature 시스템으로 관리합니다.

**기본 `[delta]` 섹션** (`programs.delta.options`):

| 옵션 | 값 | 설명 |
|------|-----|------|
| `dark` | `true` | 다크 테마 |
| `line-numbers` | `true` | diff에 줄 번호 표시 |
| `features` | `"interactive"` | 기본 적용 feature |

**`[delta "interactive"]` feature** (터미널 git diff 전용):

| 옵션 | 값 | 설명 |
|------|-----|------|
| `navigate` | `true` | `n`/`N`으로 diff 청크 간 이동 |
| `side-by-side` | `true` | 좌우 분할 diff |

> **설계 이유**: `navigate`와 `side-by-side`를 feature로 분리한 이유는 lazygit에서 비활성화하기 위함입니다. delta의 `[delta]` 기본 섹션 설정은 feature보다 우선순위가 높아서, 기본 섹션에 직접 설정하면 도구별 오버라이드가 불가능합니다.

### 동적 side-by-side 제어

`.zshenv`와 `.zshrc` precmd 훅으로 터미널 환경에 따라 side-by-side를 자동 제어합니다.

| 환경 | DELTA_FEATURES | side-by-side |
|------|:--------------:|:------------:|
| 비대화형 셸 (SSH 단일 명령, Claude Code 등) | `""` (.zshenv 기본값) | OFF |
| 대화형 + 넓은 터미널 (>= 120 컬럼) | unset (precmd) | ON |
| 대화형 + 좁은 터미널 (< 120 컬럼) | `""` (precmd) | OFF |
| lazygit | `""` (pager 설정) | OFF |

### delta pager 설정

`less -e --mouse`로 마우스 스크롤과 끝 도달 시 자동 종료를 지원합니다.

| 플래그 | 동작 |
|--------|------|
| `--mouse` | 마우스 휠 스크롤 활성화 (trade-off: less 내 텍스트 선택 불가) |
| `-e` | 끝까지 스크롤 후 한 번 더 스크롤하면 자동 종료 (q 불필요) |

> **모바일 제약**: `--mouse`는 데스크톱 마우스 휠 전용. iOS SSH 앱(Termius 등)의 터치 스크롤은 앱 레벨에서 처리되어 less에 전달되지 않음. 모바일에서는 `j`/`k`(한 줄), `Space`/`b`(한 페이지), `G`(맨 끝)로 이동.

### lazygit delta 통합

lazygit에서 delta를 pager로 사용합니다. `modules/shared/programs/lazygit/default.nix`에서 관리됩니다.

- pager: `env DELTA_FEATURES= delta --paging=never`
- `DELTA_FEATURES=` (빈 문자열): interactive feature를 리셋하여 side-by-side와 navigate 비활성화
- `--paging=never`: lazygit이 자체 스크롤을 처리하므로 delta의 less pager 비활성화

**lazygit 제한사항:**
- line-by-line staging 뷰에서는 pager가 적용되지 않음 (lazygit issue #2117)
- `--navigate`는 lazygit과 호환되지 않음 (키바인딩 충돌)

### rerere 사용법

```bash
# rerere 상태 확인
git rerere status

# 기록된 해결책 확인
git rerere diff

# 캐시 정리
rm -rf .git/rr-cache
```

### 설정 파일 위치

| 파일 | 용도 |
|------|------|
| `modules/shared/programs/git/default.nix` | Git + delta 설정 |
| `modules/shared/programs/shell/default.nix` | 동적 side-by-side 제어 (.zshenv + precmd) |
| `modules/shared/programs/lazygit/default.nix` | lazygit 설정 (delta pager 통합) |
| `~/.gitconfig` | 생성된 Git/delta 설정 (Nix 관리) |
| `~/Library/Application Support/lazygit/config.yml` | 생성된 lazygit 설정 (Nix 관리, macOS) |

## 자주 발생하는 문제

1. **delta 적용 안 됨**: `core.pager` 설정 확인, PATH에 delta 있는지 확인
2. **gitconfig 충돌**: 기존 `~/.gitconfig`가 있으면 Home Manager와 충돌
3. **rebase 역순 안 됨**: `GIT_SEQUENCE_EDITOR` 환경변수 확인
4. **lazygit에서 delta side-by-side가 꺼지지 않음**: [트러블슈팅 참조](references/troubleshooting.md#lazygit에서-delta-side-by-side-오버라이드가-안-됨)

## git-cleanup 사용법

```bash
# 삭제된 원격 브랜치와 연결된 로컬 브랜치 정리
git-cleanup

# 출력 예시:
# [gone] feature/old-feature
# [stale] feature/very-old (3 months ago)
```

## wt / wt-cleanup 사용법

```bash
# 워크트리 생성 (cd 이동 + 에디터 열기)
wt feature-branch

# 워크트리 생성 (현재 디렉토리에 머무름)
wt -s feature-branch
wt --stay feature-branch

# 워크트리 정리 (fzf 다중 선택)
wt-cleanup
```

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
- Git 설정 가이드: [references/config.md](references/config.md)
