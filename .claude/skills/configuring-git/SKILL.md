---
name: configuring-git
description: |
  Git config via Home Manager: delta, rerere, lazygit, aliases.
  Triggers: "gitconfig conflicts", "git-cleanup scripts",
  "rebase reverse display", "lazygit delta pager config",
  "git 설정 충돌", "delta 설정", "Git alias".
---

# Git 설정

Git, delta diff, lazygit, rerere 등 Git 관련 설정 가이드입니다.

## 목적과 범위

Home Manager 기반 Git 설정과 lazygit/delta 통합, 충돌 복구 절차를 다룬다.

## 빠른 참조

### 주요 기능

| 기능 | 설명 |
|------|------|
| delta | Git diff를 구문 강조로 표시 |
| lazygit (`lg`) | Git TUI (delta pager 통합) |
| rerere | 충돌 해결 패턴 기록/재사용 |
| git aliases (`s`, `l`) | 짧은 상태/로그 조회 단축 |
| 기본 정책 | `push.autoSetupRemote=true`, `merge.conflictStyle=zdiff3` |
| rebase 역순 | Interactive rebase에서 최신 커밋이 위로 |
| git-cleanup | 오래된/삭제된 브랜치 정리 |
| gdf | git diff 파일을 fzf로 선택하여 nvim으로 열기 (delta preview) |
| gdl | 직전 커밋 파일을 fzf로 선택하여 nvim으로 열기 (`gdl 3`으로 N커밋) |
| wt | Git worktree 생성 및 관리 (삭제 시 커밋 체크) |
| wt-cleanup | 워크트리 정리 (PR 상태 + 커밋 체크) |

### delta 설정 확인

```bash
# delta가 설치되어 있는지 확인
which delta

# Git에서 delta 사용 중인지 확인
git config --get core.pager

# 핵심 git 설정 확인
git config --get alias.s
git config --get alias.l
git config --get push.autoSetupRemote
git config --get merge.conflictStyle
```

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
| `$HOME/.gitconfig` | 생성된 Git/delta 설정 (Nix 관리) |
| `~/Library/Application Support/lazygit/config.yml` | 생성된 lazygit 설정 (Nix 관리, macOS) |

## 핵심 절차

1. Git 핵심 옵션(`core.pager`, `alias`, `rerere`)을 `git config --get`로 확인한다.
2. lazygit/delta 연동이 깨진 경우 `modules/shared/programs/lazygit/default.nix`를 점검한다.
3. 충돌 재현 시 rerere cache를 확인하고 필요하면 정리한다.
4. 변경 후 `git diff`, `lazygit`, rebase 흐름을 순서대로 검증한다.

## 자주 발생하는 문제

1. **delta 적용 안 됨**: `core.pager` 설정 확인, PATH에 delta 있는지 확인
2. **gitconfig 충돌**: 기존 `$HOME/.gitconfig`가 있으면 Home Manager와 충돌
3. **rebase 역순 안 됨**: `GIT_SEQUENCE_EDITOR` 환경변수 확인
4. **lazygit에서 delta side-by-side가 꺼지지 않음**: [트러블슈팅 참조](references/troubleshooting.md#lazygit에서-delta-side-by-side-오버라이드가-안-됨)

## 레퍼런스

- delta/lazygit/rebase 설정 상세: [references/config.md](references/config.md)
- gdf/git-cleanup/wt/wt-cleanup 사용법: [references/commands.md](references/commands.md)
- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
