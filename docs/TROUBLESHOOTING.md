# Troubleshooting Guide

이 문서는 nixos-config 프로젝트에서 발생한 문제와 해결 방법을 기록합니다.

> pre-commit `ai-skills-consistency` 훅은 스킬/Codex 관련 staged 변경에서 `.claude/skills` ↔ `.agents/skills` 정합성이 깨지면 커밋을 차단합니다.
> 먼저 `nrs` 실행 후 `./scripts/ai/verify-ai-compat.sh`를 통과시키세요.
> 긴급 우회: `SKIP_AI_SKILL_CHECK=1 git commit ...`

---

## wt 실행 직후 `.claude/.claude`, `.agents/.agents`가 생김

### 증상

`wt <branch>` 실행 직후:

```bash
git status --short
?? .agents/.agents/
?? .claude/.claude/
```

### 원인 (회귀 당시)

`modules/shared/scripts/git-worktree-functions.sh`의 `wt()`에서 worktree 생성 후 `.claude/.codex/.agents`를 `cp -R`로 재복사한다.
현재 저장소에서는 `.claude`, `.agents`가 이미 git-tracked라 `git worktree add`만으로 생성되므로, 재복사 시 하위 중첩(`.claude/.claude`, `.agents/.agents`)이 만들어진다.

핵심은 "과거에는 untracked라 복사가 필요했다"는 전제가 현재와 달라졌다는 점이다.

### 영향

1. source worktree가 오염된 상태에서 다시 `wt`를 실행하면 `.claude/.claude/.claude`처럼 재귀적으로 악화될 수 있음
2. `.claude/.claude/worktrees`까지 복제되어 불필요한 용량 증가
3. `.agents/.agents`가 Codex 투영처럼 보여 디버깅 혼선을 유발

### 진단 명령

```bash
find .claude -maxdepth 4 -type d -name .claude
find .agents -maxdepth 4 -type d -name .agents
rg -n 'cp -R "\$source_root/\$_dir" "\$worktree_dir/\$_dir"' modules/shared/scripts/git-worktree-functions.sh
```

### 임시 정리

```bash
rm -rf .claude/.claude .agents/.agents
```

### 영구 수정 원칙

1. 대상 디렉토리가 이미 존재하면 복사를 스킵한다.
2. 병합 복사(`cp -R source/. target/`)로 바꾸지 않는다. 세션 부산물/중첩 오염 전파 위험이 더 크다.
3. 수정 후 `wt -s <temp-branch>`로 생성 테스트하고 `git status --short`가 깨끗한지 확인한다.

### 자동 회귀 방지

1. `wt()` 내부에서 `.claude/.claude`, `.agents/.agents`, `.codex/.codex`를 감지하면 즉시 실패하도록 가드를 둔다.
2. `tests/run-wt-regression.sh`로 `wt` 생성 후 중첩 디렉토리 회귀를 자동 검증한다.
3. `lefthook` pre-commit에서 `modules/shared/scripts/git-worktree-functions.sh`가 변경되면 위 테스트를 자동 실행한다.

## Termius에서 Codex 스크롤 히스토리 소실

### 증상
Termius(iOS)에서 SSH로 Codex CLI를 실행하면 응답 완료 후에도 위로 스크롤이 잘 되지 않거나, 히스토리가 사라진 것처럼 보임.

### 빠른 결론
이번 저장소 기준 재현 결과:
1. `--no-alt-screen` 적용 후에도 증상 지속
2. `codex-cli 0.96.0` 회귀 테스트에서도 동일 증상
3. Mosh 미사용(SSH-only) 환경에서도 발생

즉, 설정 실수보다는 **Termius + Codex TUI 호환성 이슈** 가능성이 높음.

### 임시 우회
1. 긴 출력 확인은 `codex exec` 우선
2. TUI에서 출력 누락/스크롤 불가 시 `/resume`으로 재표시 시도

### 상세 기록
- `docs/TRIAL_AND_ERROR.md`의 `2026-02-13: Codex CLI + Termius 스크롤 히스토리 소실 (SSH)`

---

## ripgrep glob 패턴이 작동하지 않음

### 증상
ripgrep에서 `-g '!directory/**'` 형태의 제외 glob을 사용했으나, 예상과 다르게 **모든 파일이 검색되지 않거나** 제외가 적용되지 않음.

```bash
# 의도: _archive, _trash 폴더 제외하고 검색
rg --glob '!_archive/**' --glob '!_trash/**' "pattern" ~/.tmux/pane-notes

# 결과: 아무것도 출력되지 않음 (모든 파일이 제외됨)
```

### 원인

1. **포함 glob 누락**: 제외 glob(`!...`)만 사용하면 ripgrep이 "어떤 파일도 포함 조건을 만족하지 않음"으로 해석하여 모든 파일을 제외함
   - ripgrep GUIDE.md: *"the presence of at least one non-blacklist glob will institute a requirement that every file searched must match at least one glob"*

2. **절대경로와 glob 비호환**: glob 패턴은 gitignore 시맨틱을 따르며, CWD 기준 상대경로에서만 안정적으로 동작. 절대경로(예: `~/.tmux/pane-notes`)를 사용하면 glob이 예상대로 작동하지 않을 수 있음.

### 해결 방법

#### 1. 포함 glob을 먼저 지정
```bash
# 잘못된 예 (제외만 있음)
rg -g '!_archive/**' "pattern" .

# 올바른 예 (포함 먼저, 제외 나중)
rg -g '*.md' -g '!_archive/**' -g '!_trash/**' "pattern" .
```

#### 2. 상대경로 사용
```bash
# 잘못된 예 (절대경로)
rg -g '!_archive/**' "pattern" /absolute/path/to/notes

# 올바른 예 (cd 후 상대경로)
cd /absolute/path/to/notes && rg -g '*.md' -g '!_archive/**' "pattern" .
```

#### 3. 결과를 절대경로로 변환 (필요시)
```bash
cd "$NOTES_DIR" && rg -g '*.md' -g '!_archive/**' "pattern" . | sed "s|^\./|$NOTES_DIR/|"
```

### 디버깅 방법

`--debug` 플래그로 glob 적용 상태 확인:
```bash
rg --debug "pattern" . -g '*.md' -g '!_archive/**' 2>&1 | grep -E "(ignoring|whitelisting)"
```

출력 예시:
```
ignoring ./_archive/file.md: Ignore(IgnoreMatch(Override(Glob(...))))
whitelisting ./notes/file.md: Whitelist(IgnoreMatch(Override(Glob(...))))
```

### 참고 자료
- [ripgrep GUIDE.md](https://github.com/BurntSushi/ripgrep/blob/master/GUIDE.md)
- [GitHub Discussion #2128: How can I exclude a directory?](https://github.com/BurntSushi/ripgrep/discussions/2128)
- [GitHub Issue #691: Exclusion globbing does not work with double quotes](https://github.com/BurntSushi/ripgrep/issues/691)

### 관련 파일
- `modules/shared/programs/tmux/files/scripts/pane-search.sh`

---
