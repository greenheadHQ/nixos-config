# Neovim (LazyVim) 가이드

> Vim 초보자를 위한 실사용 가이드. 이 프로젝트의 Neovim은 LazyVim 배포판 기반.

## 목차

- [Vim 기초](#vim-기초)
  - [모드](#모드)
  - [이동 (모션)](#이동-모션)
  - [편집](#편집)
  - [텍스트 오브젝트](#텍스트-오브젝트)
- [LazyVim 핵심 키맵 (외워두면 좋은 것들)](#lazyvim-핵심-키맵-외워두면-좋은-것들)
  - [파일/검색](#파일검색)
  - [코드 탐색 (LSP)](#코드-탐색-lsp)
  - [편집 도구](#편집-도구)
  - [버퍼 (탭)](#버퍼-탭)
  - [Git](#git)
  - [커스텀 키맵](#커스텀-키맵)
- [플러그인 관리](#플러그인-관리)
- [자주 묻는 질문](#자주-묻는-질문)

---

## Vim 기초

### 모드

Vim은 **모달 에디터** — 같은 키가 모드에 따라 다르게 동작한다.

| 모드 | 진입 | 용도 | 빠져나오기 |
|------|------|------|------------|
| **Normal** | `Esc` 또는 `jk` | 이동, 명령 실행 | (기본 모드) |
| **Insert** | `i`, `a`, `o` | 텍스트 입력 | `Esc` / `jk` |
| **Visual** | `v`, `V`, `Ctrl+v` | 텍스트 선택 | `Esc` |
| **Command** | `:` | Ex 명령 실행 | `Enter` / `Esc` |

핵심 규칙: **글자를 타이핑하려면 Insert 모드**, **그 외 모든 작업은 Normal 모드**.

### 이동 (모션)

```
기본 이동:
  h ← j ↓ k ↑ l →

단어 단위:
  w → 다음 단어 처음       b → 이전 단어 처음
  e → 현재/다음 단어 끝

줄 내 이동:
  0 → 줄 맨 앞             $ → 줄 맨 끝
  ^ → 첫 글자 (공백 제외)

파일 이동:
  gg → 파일 맨 위           G → 파일 맨 아래
  {숫자}G → 해당 줄로 이동   (예: 42G → 42번 줄)

화면 이동:
  Ctrl+d → 반 페이지 아래    Ctrl+u → 반 페이지 위

검색:
  /{패턴} → 앞으로 검색      n → 다음 결과   N → 이전 결과
```

### 편집

```
삽입:
  i → 커서 앞에 삽입         a → 커서 뒤에 삽입
  I → 줄 맨 앞에 삽입        A → 줄 맨 뒤에 삽입
  o → 아래에 새 줄            O → 위에 새 줄

삭제:
  x → 한 글자 삭제           dd → 한 줄 삭제
  dw → 단어 삭제             D → 커서~줄 끝 삭제

복사/붙여넣기:
  yy → 한 줄 복사 (yank)     p → 아래에 붙여넣기
  yw → 단어 복사              P → 위에 붙여넣기

변경 (삭제 + Insert 모드 진입):
  cc → 줄 전체 변경           cw → 단어 변경
  C → 커서~줄 끝 변경

실행 취소/재실행:
  u → 실행 취소 (undo)        Ctrl+r → 재실행 (redo)

반복:
  . → 마지막 편집 작업 반복   (매우 유용!)
```

### 텍스트 오브젝트

`동작` + `범위` + `오브젝트` 조합으로 강력한 편집이 가능하다.

| 명령 | 의미 | 예시 |
|------|------|------|
| `diw` | delete inner word | 커서 위 단어 삭제 |
| `ci"` | change inner " | 따옴표 안 내용을 변경 |
| `da(` | delete around ( | 괄호 포함해서 삭제 |
| `yi{` | yank inner { | 중괄호 안 내용 복사 |
| `vit` | visual inner tag | HTML 태그 안 내용 선택 |

`i` = inner (안쪽만), `a` = around (감싸는 것 포함)

---

## LazyVim 핵심 키맵 (외워두면 좋은 것들)

> `<leader>` = **Space 키**. which-key가 설치되어 있어서 Space를 누르고 기다리면 가능한 키 목록이 팝업으로 표시된다. 모르겠으면 **Space 누르고 읽기**.

### 파일/검색

| 키 | 동작 | VS Code 대응 |
|----|------|-------------|
| `<leader>ff` | 파일 이름으로 검색 | `Cmd+P` |
| `<leader>fg` | 파일 내용(텍스트)으로 검색 | `Cmd+Shift+F` |
| `<leader>fb` | 열린 버퍼 목록에서 검색 | 탭 전환 |
| `<leader>fr` | 최근 파일 목록 | Recent Files |
| `<leader>e` | 파일 탐색기 토글 (neo-tree) | Explorer 패널 |
| `<leader><leader>` | 프로젝트 내 파일 찾기 | `Cmd+P` |

### 코드 탐색 (LSP)

| 키 | 동작 | VS Code 대응 |
|----|------|-------------|
| `gd` | 정의로 이동 | `F12` / `Cmd+Click` |
| `gr` | 참조 찾기 | `Shift+F12` |
| `K` | 호버 문서 (설명 팝업) | 마우스 호버 |
| `<leader>ca` | 코드 액션 (빠른 수정) | `Cmd+.` |
| `<leader>cr` | 이름 변경 (rename) | `F2` |
| `<leader>cd` | 줄 진단(에러/경고) 표시 | 문제 패널 |
| `]d` / `[d` | 다음/이전 진단으로 이동 | |
| `<leader>cf` | 파일 포맷 | `Shift+Alt+F` |

### 편집 도구

| 키 | 동작 | 설명 |
|----|------|------|
| `ysiw"` | 단어를 `""`로 감싸기 | nvim-surround |
| `cs"'` | `"` → `'` 변경 | nvim-surround |
| `ds"` | `""` 제거 | nvim-surround |
| `gcc` | 줄 주석 토글 | Comment |
| `gc` (Visual) | 선택 영역 주석 토글 | Comment |

### 버퍼 (탭)

| 키 | 동작 |
|----|------|
| `H` | 이전 버퍼 (왼쪽 탭) |
| `L` | 다음 버퍼 (오른쪽 탭) |
| `<leader>bd` | 현재 버퍼 닫기 |
| `<leader>bo` | 다른 버퍼 모두 닫기 |

### Git

| 키 | 동작 |
|----|------|
| `<leader>gg` | lazygit 열기 (전체 Git TUI) |
| `<leader>gf` | lazygit 파일 상태 |
| `]h` / `[h` | 다음/이전 git hunk로 이동 |

### 커스텀 키맵

| 키 | 동작 | 이유 |
|----|------|------|
| `jk` | Esc (Insert 모드) | iPad 소프트웨어 키보드 UX |
| `Ctrl+\` | 터미널 Normal 모드 | `:terminal`에서 탈출 |

---

## 플러그인 관리

```vim
:Lazy               " 플러그인 매니저 UI 열기
:Lazy update         " 모든 플러그인 최신으로 업데이트
:Lazy restore        " lazy-lock.json 기준으로 복원
:Lazy health         " 플러그인 상태 점검
```

업데이트 후 `lazy-lock.json` 변경사항을 커밋해야 다른 머신과 동기화된다.

---

## 자주 묻는 질문

### Q: 키를 뭘 눌러야 할지 모르겠다

**A:** Normal 모드에서 **Space**를 누르고 기다리면 which-key 팝업이 뜬다. 카테고리별로 가능한 키가 전부 나열된다.

### Q: 파일을 저장하려면?

**A:** Normal 모드에서 `:w` 입력 후 Enter. LazyVim은 Insert 모드를 벗어나면 자동 저장하므로, 보통은 직접 저장할 필요 없다.

### Q: 터미널 색상이 이상하다

**A:** 터미널이 true color를 지원해야 한다. Ghostty, iTerm2, Kitty 등은 기본 지원. Termius는 제한적.

```bash
# true color 테스트
echo -e "\033[38;2;255;100;0mTRUECOLOR\033[0m"
```

### Q: LSP가 동작하지 않는다 (자동완성/에러 표시 없음)

**A:** `:LspInfo`로 활성 LSP 서버를 확인한다. 서버가 0개면 해당 파일 타입의 LSP가 extraPackages에 없거나 PATH에 없는 것.

```vim
:LspInfo             " 현재 버퍼의 LSP 서버 상태
:checkhealth lsp     " LSP 전체 진단
```

### Q: 포맷이 저장 시 자동으로 안 된다

**A:** LazyVim은 저장 시 자동 포맷이 기본이다. `<leader>cf`로 수동 포맷을 먼저 시도해본다. 동작하면 autoformat 설정 문제, 안 되면 포매터 바이너리 문제.

```vim
:LazyFormatInfo      " 현재 파일의 포매터 설정 확인
```

### Q: Mason이 뜬다 / :Mason 명령이 동작한다

**A:** `disabled.lua`에서 Mason이 제대로 비활성화되지 않은 것. `mason-org/mason.nvim` prefix를 확인. `williamboman/`으로 되어있으면 매칭 실패.

### Q: Insert 모드에서 "j"를 누르면 잠깐 멈춘다

**A:** `jk` → Esc 매핑 때문. "j" 입력 후 "k"를 기다리는 시간(기본 300ms) 동안 멈춤이 발생한다. "jk"를 사용하지 않으려면 `keymaps.lua`에서 해당 줄을 삭제하면 된다.

### Q: neo-tree에서 숨김 파일이 안 보인다

**A:** 현재 설정은 dotfile과 gitignored 파일을 모두 표시한다. 안 보인다면 `H`를 눌러 숨김 파일 토글을 확인.

### Q: nvim을 처음 열면 에러가 뜬다

**A:** 첫 실행 시 lazy.nvim이 플러그인을 다운로드하고 tree-sitter 파서를 컴파일한다. 네트워크가 필요하며, 완료까지 잠깐 기다려야 한다. 에러가 지속되면:

```bash
# 클린 재설치
rm -rf ~/.local/share/nvim ~/.local/state/nvim ~/.cache/nvim
nvim
```

### Q: 이 설정을 수정하고 싶다

**A:** `~/.config/nvim`이 이 repo의 `modules/shared/programs/neovim/files/nvim/`으로 심볼릭 링크되어 있다. 해당 디렉토리의 Lua 파일을 직접 수정하면 nvim 재시작 시 반영된다. `nrs` 빌드가 필요 없다.
