# Troubleshooting Guide

이 문서는 nixos-config 프로젝트에서 발생한 문제와 해결 방법을 기록합니다.

> pre-commit `ai-skills-consistency` 훅은 스킬/Codex 관련 staged 변경에서 `.claude/skills` ↔ `.agents/skills` 정합성이 깨지면 커밋을 차단합니다.
> 먼저 `nrs` 실행 후 `./scripts/ai/verify-ai-compat.sh`를 통과시키세요.
> 긴급 우회: `SKIP_AI_SKILL_CHECK=1 git commit ...`

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
