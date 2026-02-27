# 트러블슈팅

Git 관련 문제와 해결 방법을 정리합니다.

## 목차

- [wt 직후 .claude/.claude, .agents/.agents 중첩 디렉토리가 생김](#wt-직후-claudeclaude-agentsagents-중첩-디렉토리가-생김)
- [lazygit에서 delta side-by-side 오버라이드가 안 됨](#lazygit에서-delta-side-by-side-오버라이드가-안-됨)
- [비대화형 SSH에서 side-by-side가 비활성화되지 않음](#비대화형-ssh에서-side-by-side가-비활성화되지-않음)
- [iOS SSH 앱에서 delta 마우스 스크롤이 안 됨](#ios-ssh-앱에서-delta-마우스-스크롤이-안-됨)
- [lazygit config.yml permission denied](#lazygit-configyml-permission-denied)
- [delta가 적용되지 않음](#delta가-적용되지-않음)
- [~/.gitconfig과 Home Manager 설정이 충돌함](#gitconfig과-home-manager-설정이-충돌함)
- [git commit 시 Author identity unknown](#git-commit-시-author-identity-unknown)

---

## wt 직후 .claude/.claude, .agents/.agents 중첩 디렉토리가 생김

**증상**:

```bash
git status --short
?? .agents/.agents/
?? .claude/.claude/
```

**원인 (회귀 당시)**:

`modules/shared/scripts/git-worktree-functions.sh`의 `wt()`가 worktree 생성 후 `.claude/.codex/.agents`를 `cp -R`로 재복사한다.
현재 저장소에서는 `.claude`/`.agents`가 이미 git-tracked라 `git worktree add` 단계에서 존재하므로, 재복사 시 하위 중첩 디렉토리(`.claude/.claude`, `.agents/.agents`)가 생성된다.

핵심 전제 붕괴:
- 과거 전제: 이 디렉토리들은 worktree에 자동 포함되지 않음
- 현재 상태: `.claude`, `.agents`는 추적되어 자동 포함됨

**왜 위험한가**:

- source worktree가 중첩된 상태에서 다시 `wt`를 실행하면 `.claude/.claude/.claude`처럼 재귀적으로 오염될 수 있다.
- `.claude/.claude/worktrees`까지 복제되어 용량/노이즈가 급격히 늘어난다.
- `.agents/.agents`는 Codex 투영 경로처럼 보이지만 잘못된 깊이의 복사본이라 혼동을 유발한다.

**진단**:

```bash
# 중첩 여부 확인
find .claude -maxdepth 4 -type d -name .claude
find .agents -maxdepth 4 -type d -name .agents

# 복사 회귀 여부 확인 (wt 구현)
rg -n 'cp -R "\$source_root/\$_dir" "\$worktree_dir/\$_dir"' modules/shared/scripts/git-worktree-functions.sh
```

**임시 정리**:

```bash
rm -rf .claude/.claude .agents/.agents
```

**영구 수정 가이드**:

1. 대상 디렉토리가 이미 존재하면 복사를 스킵한다.
2. 병합 복사(`cp -R source/. target/`)로 바꾸지 않는다.
3. 수정 후 `wt -s <temp-branch>`로 생성 테스트하고, `git status --short`가 깨끗한지 확인한다.

**자동 회귀 방지**:

1. `wt()` 내부에 중첩 디렉토리 감지 가드가 있어 `.claude/.claude`, `.agents/.agents`, `.codex/.codex` 발견 시 즉시 실패한다.
2. `tests/run-wt-regression.sh`를 통해 `wt` 생성 후 중첩 여부를 자동 검증한다.
3. `lefthook` pre-commit에서 `modules/shared/scripts/git-worktree-functions.sh` 변경 시 위 테스트가 자동 실행된다.

## lazygit에서 delta side-by-side 오버라이드가 안 됨

**증상**: lazygit에서 delta를 pager로 설정했는데, `[delta "lazygit"]` feature로 `side-by-side = false`를 지정해도 side-by-side가 계속 활성화됨

**원인**: delta의 우선순위 구조 때문.

```
우선순위 (높→낮):
1. [delta] 기본 섹션 (gitconfig)
2. 환경변수 (DELTA_FEATURES)
3. CLI 플래그
4. feature 섹션 ([delta "feature-name"])
```

`[delta]` 기본 섹션에 `side-by-side = true`가 있으면 **어떤 방법으로도 오버라이드 불가**:
- `--side-by-side=false` → boolean 플래그라 `=false` 문법 미지원
- `--features lazygit` → feature가 기본 섹션보다 우선순위 낮음
- `DELTA_FEATURES=+` → 기본 섹션 설정은 영향받지 않음

**해결**: `side-by-side`와 `navigate`를 `[delta]`에서 feature로 분리

```nix
# git/default.nix — 기본 섹션에서 제거하고 feature로 이동
programs.delta.options = {
  dark = true;
  line-numbers = true;
  features = "interactive";  # side-by-side, navigate를 feature에 위임
};

programs.git.settings."delta \"interactive\"" = {
  side-by-side = true;
  navigate = true;
};
```

```nix
# lazygit/default.nix — DELTA_FEATURES=""로 feature 리셋
pager = "env DELTA_FEATURES= delta --paging=never";
```

`DELTA_FEATURES=` (빈 문자열)은 gitconfig의 `features = interactive` 설정을 오버라이드하여 빈 feature 리스트로 대체합니다.

> **주의**: `DELTA_FEATURES=+` (플러스)는 동작하지 않음. 빈 문자열(`""`)만 feature를 리셋함.

---

## 비대화형 SSH에서 side-by-side가 비활성화되지 않음

**증상**: iPhone SSH 등 좁은 터미널에서 `git show`/`git diff` 실행 시 side-by-side가 활성화됨

**원인**: 동적 side-by-side 제어(`_update_delta_features`)가 `.zshrc`의 `precmd` 훅으로 구현되어 있어, 비대화형 셸(`.zshrc` 미소싱)에서는 `DELTA_FEATURES`가 설정되지 않음. delta가 gitconfig의 `features = interactive` → `side-by-side = true`를 그대로 사용.

**진단**:

```bash
echo $-                          # 'i' 없으면 비대화형
echo $COLUMNS                    # 0이면 터미널 너비 미감지
echo ${DELTA_FEATURES+SET}       # 출력 없으면 DELTA_FEATURES 미설정
```

**해결**: `.zshenv`에서 `DELTA_FEATURES=""` 기본값 설정

```nix
# modules/shared/programs/shell/default.nix — envExtra (.zshenv)
export DELTA_FEATURES=""
```

`.zshenv`는 모든 zsh 호출(대화형/비대화형)에서 소싱되므로, 비대화형 셸에서도 side-by-side가 비활성화됩니다. 대화형 셸에서는 `.zshrc`의 precmd 훅이 터미널 너비에 따라 동적으로 오버라이드합니다.

---

## iOS SSH 앱에서 delta 마우스 스크롤이 안 됨

**증상**: delta pager에 `--mouse` 플래그를 설정했는데, Termius 등 iOS SSH 앱에서 터치 스크롤로 diff를 탐색할 수 없음. 화면 하단에 `:` 프롬프트가 표시되고 `q`로만 종료 가능.

**원인**: `less --mouse`는 터미널이 **마우스 이벤트 이스케이프 시퀀스**를 전달해야 동작합니다. iOS SSH 앱의 터치 스크롤은 앱 레벨에서 처리되어(터미널 스크롤백 버퍼 이동) less에 마우스 이벤트로 전달되지 않습니다.

```
[터치 스크롤] → iOS 앱이 가로챔 (스크롤백 버퍼) → less에 미전달
[마우스 휠]   → 터미널이 이스케이프 시퀀스 전송 → less가 수신 → 스크롤
```

**대안**: 모바일에서는 키보드 단축키로 탐색

| 키 | 동작 |
|----|------|
| `j` / `k` | 한 줄 아래 / 위 |
| `Space` / `b` | 한 페이지 아래 / 위 |
| `d` / `u` | 반 페이지 아래 / 위 |
| `G` | 맨 끝 (`-e` 플래그: 한 번 더 누르면 자동 종료) |
| `q` | 즉시 종료 |

> **참고**: `--mouse`는 데스크톱 터미널(MacBook Ghostty, iTerm2 등)의 마우스 휠에서는 정상 동작합니다. 모바일 전용 제약사항입니다.

---

## lazygit config.yml permission denied

**증상**: lazygit 실행 시 `permission denied` 에러

```
While attempting to write back migrated user config to
.../lazygit/config.yml, an error occurred:
open .../lazygit/config.yml: permission denied
```

**원인**: Home Manager가 config.yml을 Nix store 심링크로 관리하므로 읽기 전용. lazygit이 `git.paging`을 `git.pagers` 배열로 자동 마이그레이션하려 할 때 쓰기 실패.

**해결**: 처음부터 새 형식(`git.pagers` 배열)을 사용

```nix
# 구 형식 (마이그레이션 시도 발생)
git.paging = { colorArg = "always"; pager = "delta ..."; };

# 신 형식 (lazygit 0.56.0+, 마이그레이션 불필요)
git.pagers = [{ colorArg = "always"; pager = "delta ..."; }];
```

---

## delta가 적용되지 않음

**증상**: `programs.delta.enable = true`를 설정했는데 `git diff`에서 delta가 사용되지 않음

**원인**: `enableGitIntegration`이 명시적으로 설정되지 않음. Home Manager 최신 버전에서는 자동 활성화가 deprecated됨.

**진단**:
```bash
# delta 설치 확인
which delta
# 예상: /etc/profiles/per-user/<username>/bin/delta

# git pager 설정 확인
git config --get core.pager
# 비어있으면 문제
```

**해결**: `enableGitIntegration = true` 추가

```nix
# modules/shared/programs/git/default.nix
programs.delta = {
  enable = true;
  enableGitIntegration = true;  # 이 줄이 필수!
  options = {
    dark = true;
    line-numbers = true;
    features = "interactive";
  };
};
```

> **참고**: `programs.delta`는 `programs.git`과 별도 모듈입니다. 이전에는 `programs.git.delta`였지만, 현재는 분리되었습니다.

---

## ~/.gitconfig과 Home Manager 설정이 충돌함

**증상**: NixOS로 Git 설정을 관리하는데, 수동 설정(`~/.gitconfig`)이 계속 적용됨

**원인**: Git은 여러 설정 파일을 병합하여 사용합니다:

| 우선순위 | 경로 | 설명 |
|---------|------|------|
| 1 | `~/.gitconfig` | 수동 관리 (존재하면 읽음) |
| 2 | `~/.config/git/config` | Home Manager 관리 |
| 3 | `.git/config` | 프로젝트별 로컬 |

Home Manager는 XDG 표준 경로(`~/.config/git/config`)를 사용하므로, `~/.gitconfig`이 있으면 두 설정이 병합됩니다.

**해결**: `~/.gitconfig` 삭제

```bash
# 백업 후 삭제 (권장)
mv ~/.gitconfig ~/.gitconfig.backup

# 또는 바로 삭제
rm ~/.gitconfig
```

**확인**:
```bash
# Home Manager가 관리하는 설정만 표시되어야 함
git config --list --show-origin | grep "\.config/git"
```

---

## git commit 시 Author identity unknown

> **발생 시점**: NixOS 초기 설치 시

**증상**: git commit 실행 시 author 정보 없음 에러.

```
$ git commit -m "message"
Author identity unknown

*** Please tell me who you are.

Run
  git config --global user.email "you@example.com"
  git config --global user.name "Your Name"
```

**원인**: 새로 설치된 환경에서 git user 설정이 없음. Home Manager의 git 모듈이 아직 적용되지 않은 상태.

**해결**: 수동으로 git config 설정

```bash
git config --global user.email "your-email@example.com"
git config --global user.name "your-username"
```

**참고**: Home Manager의 `programs.git` 설정이 적용되면 이 설정은 자동으로 관리됩니다. 하지만 첫 rebuild 전에 commit이 필요한 경우 수동 설정이 필요합니다.
