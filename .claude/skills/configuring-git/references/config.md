# Git 설정

Git 관련 설정 및 도구 구성입니다.

## 목차

- [개발 도구](#개발-도구)
- [delta 설정 (feature 구조)](#delta-설정-feature-구조)
- [동적 side-by-side 제어](#동적-side-by-side-제어)
- [delta pager 설정](#delta-pager-설정)
- [lazygit delta 통합](#lazygit-delta-통합)
- [Interactive Rebase 역순 표시](#interactive-rebase-역순-표시)

---

## 개발 도구

| 도구      | 설명                                      | 설정 파일 |
| --------- | ----------------------------------------- | --------- |
| `git`     | 버전 관리                                 | `modules/shared/programs/git/default.nix` |
| `delta`   | Git diff 시각화 (구문 강조, line-numbers) | `modules/shared/programs/git/default.nix` |
| `lazygit` | Git TUI (delta pager 통합)                | `modules/shared/programs/lazygit/default.nix` |
| `gh`      | GitHub CLI                                | `modules/shared/programs/git/default.nix` |

### delta 설정 (feature 구조)

delta 옵션은 **기본 섹션**과 **feature**로 분리하여 도구별 오버라이드를 지원합니다.

**기본 `[delta]` 섹션** (`programs.delta.options`):

| 옵션 | 값 | 설명 |
|------|-----|------|
| `dark` | `true` | 다크 테마 |
| `line-numbers` | `true` | diff에 줄 번호 표시 |
| `pager` | `"less -e --mouse"` | 마우스 스크롤 + 끝 도달 시 자동 종료 |
| `features` | `"interactive"` | 기본 적용 feature |

**`[delta "interactive"]` feature** (`programs.git.settings`):

| 옵션 | 값 | 설명 |
|------|-----|------|
| `navigate` | `true` | `n`/`N`으로 diff 청크 간 이동 |
| `side-by-side` | `true` | 좌우 분할 diff |

> **설계 이유**: `navigate`와 `side-by-side`를 feature로 분리한 이유는 lazygit 등 외부 도구에서 비활성화하기 위함. delta의 `[delta]` 기본 섹션 설정은 feature/CLI/환경변수보다 우선순위가 높아서 기본 섹션에 직접 넣으면 오버라이드 불가.

### 동적 side-by-side 제어

`.zshenv`와 `.zshrc` precmd 훅으로 터미널 환경에 따라 side-by-side를 자동 제어합니다. 설정 파일: `modules/shared/programs/shell/default.nix`.

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

`modules/shared/programs/lazygit/default.nix`에서 `programs.lazygit`으로 관리됩니다.

**pager 설정:**

```yaml
# 생성되는 config.yml
git:
  pagers:
  - colorArg: always
    pager: env DELTA_FEATURES= delta --paging=never
```

| 설정 | 설명 |
|------|------|
| `colorArg: always` | git이 컬러 출력을 delta에 전달 |
| `DELTA_FEATURES=` | interactive feature 리셋 (side-by-side, navigate 비활성화) |
| `--paging=never` | lazygit이 자체 스크롤 처리하므로 delta의 less pager 비활성화 |

**lazygit 제한사항:**

| 제한 | 설명 |
|------|------|
| staging 뷰 pager 미적용 | line-by-line staging에서 delta 미사용 (lazygit issue #2117) |
| `--navigate` 미지원 | lazygit 키바인딩과 충돌 |
| 터미널 리사이즈 | diff pager가 리사이즈에 재실행되지 않음 (issue #4415) |

## Interactive Rebase 역순 표시

`git rebase -i` 실행 시 Fork GUI처럼 **최신 커밋이 위**, 오래된 커밋이 아래에 표시됩니다.

| CLI (기본)              | CLI (적용 후)           | Fork GUI                |
| ----------------------- | ----------------------- | ----------------------- |
| 오래된 → 최신 (위→아래) | 최신 → 오래된 (위→아래) | 최신 → 오래된 (위→아래) |

**구현 방식:**

- `sequence.editor`에 커스텀 스크립트 설정
- 편집 전: 커밋 라인을 역순 정렬하여 표시
- 편집 후: 원래 순서로 복원 (rebase 동작 정상 유지)
- `pkgs.writeShellScript`로 Nix store에서 스크립트 관리
- 에디터: `${EDITOR}` 환경변수 사용, fallback은 neovim (`${pkgs.neovim}/bin/nvim`)

**주의사항:**

- squash/fixup은 **아래쪽 커밋**이 **위쪽 커밋**으로 합쳐집니다 (Fork GUI와 동일)
- `git rebase --edit-todo`에서도 역순 표시가 적용됩니다
