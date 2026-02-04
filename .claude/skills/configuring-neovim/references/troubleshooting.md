# Neovim 트러블슈팅

## 목차

- [LSP 서버가 시작되지 않음](#lsp-서버가-시작되지-않음)
- [tree-sitter 파서 컴파일 실패](#tree-sitter-파서-컴파일-실패)
- [Mason이 여전히 활성화됨](#mason이-여전히-활성화됨)
- [lazy-lock.json 호스트 간 충돌](#lazy-lockjson-호스트-간-충돌)
- [심볼릭 링크 깨짐 (~/.config/nvim)](#심볼릭-링크-깨짐-confignvim)
- [Termius 키 제한](#termius-키-제한)
- [한국어 IME 전환](#한국어-ime-전환)
- [플러그인 업데이트](#플러그인-업데이트)
- [Nix 빌드 실패 (extraPackages)](#nix-빌드-실패-extrapackages)
- [ESLint 진단 중복](#eslint-진단-중복)
- [macOS에서 nrs 빌드가 수십 분 멈춤 (LLVM 소스 빌드)](#macos에서-nrs-빌드가-수십-분-멈춤-llvm-소스-빌드)
- [marksman이 Swift 소스 빌드를 트리거 (빌드 실패)](#marksman이-swift-소스-빌드를-트리거-빌드-실패)
- [indent-blankline setup 함수 호출 실패](#indent-blankline-setup-함수-호출-실패)
- [tree-sitter CLI 누락 (파서 컴파일 불가)](#tree-sitter-cli-누락-파서-컴파일-불가)
- [mini.surround 조직 이름 변경 경고](#minisurround-조직-이름-변경-경고)
- [which-key 사용법](#which-key-사용법)
- [파일 저장](#파일-저장)
- [터미널 true color](#터미널-true-color)
- [자동 포맷 미동작](#자동-포맷-미동작)
- [jk 매핑 딜레이](#jk-매핑-딜레이)
- [숨김 파일 표시](#숨김-파일-표시)
- [버퍼 탐색 불가](#버퍼-탐색-불가)
- [첫 실행 시 에러](#첫-실행-시-에러)
- [설정 파일 위치](#설정-파일-위치)

## LSP 서버가 시작되지 않음

```bash
# 1. LSP 바이너리가 PATH에 있는지 확인
nvim -c ':!which vtsls'
nvim -c ':!which nil'

# 2. :LspInfo로 활성 서버 확인
:LspInfo

# 3. extraPackages 확인 (Nix wrapper PATH)
nvim -c ':!echo $PATH' | tr ':' '\n' | grep nix
```

**원인**: `extraPackages`는 `--suffix PATH`로 추가됨. direnv가 제공하는 도구가 우선.
프로젝트 `.envrc`가 다른 버전을 제공하면 해당 버전이 사용됨 (의도된 동작).

## tree-sitter 파서 컴파일 실패

```
Error: CC not found
```

**원인**: NixOS에서 `gcc`가 PATH에 없음.
**해결**: `extraPackages`에 `pkgs.gcc` 포함 확인.

```bash
nvim -c ':!which gcc'
:TSInstall nix  # 컴파일 테스트
```

## Mason이 여전히 활성화됨

```vim
:Mason  " 이 명령이 동작하면 비활성화 실패
```

**원인**: `disabled.lua`에서 `williamboman/mason.nvim` 사용 (잘못된 org명).
**해결**: `mason-org/mason.nvim`으로 변경.

```lua
-- lua/plugins/disabled.lua
{ "mason-org/mason.nvim", enabled = false },
{ "mason-org/mason-lspconfig.nvim", enabled = false },
```

## lazy-lock.json 호스트 간 충돌

```bash
# macOS에서 생성된 lock 파일과 NixOS에서 충돌 시
git checkout --theirs lazy-lock.json
nvim -c ':Lazy restore'  # lock 파일 기준으로 재설치
```

## 심볼릭 링크 깨짐 (~/.config/nvim)

```bash
ls -la ~/.config/nvim
# → nixos-config repo 경로로 연결되어야 함

# 깨진 경우: 기존 디렉토리가 남아있을 수 있음
rm -rf ~/.config/nvim  # 기존 디렉토리 삭제
nrs                     # Home Manager가 심볼릭 링크 재생성
```

**주의**: HM은 디렉토리 → 심볼릭 링크 자동 교체 불가. 기존 디렉토리를 수동 삭제해야 함.

## Termius 키 제한

| 문제 | 우회 |
|------|------|
| Esc 키 접근 어려움 | `jk` 매핑 (Insert 모드) |
| Ctrl 조합 불편 | leader(Space) 기반 키맵 사용 |
| OSC 52 미지원 | tmux-thumbs (`prefix+F`)로 클립보드 보완 |
| 한글 입력 깨짐 | 알려진 Termius 제한. 영문으로 입력 후 변환 |

## 한국어 IME 전환

외부 앱에서 한글을 쓰다가 Neovim으로 돌아왔을 때 Normal 모드에서 키맵이 동작하지 않는 문제.

**현재 구조** (macOS 전용, `macism` 필수):

| 레이어 | 도구 | 파일 | 역할 |
|--------|------|------|------|
| 1차 | FocusGained autocmd | `autocmds.lua` | 외부 앱 복귀 시 영문 전환 → 내장/플러그인 명령 정상 동작 |
| 2차 | im-select.nvim | `editor.lua` | Insert↔Normal 전환 시 IM 자동 전환 |

**진단**:
```vim
" FocusGained autocmd 확인
:autocmd FocusGained

" macism 동작 확인 (터미널에서)
macism    " 현재 입력소스 ID 출력
```

**langmap/langmapper를 사용하지 않는 이유**: 한글 IME는 자음 입력 시 조합(pre-edit) 상태로 대기하여 Neovim에 즉시 전달되지 않음. 이로 인해 `<leader>ff` 같은 키맵에서 extra keystroke가 필요해짐. 러시아어(키릴)와 달리 1:1 매핑이 불가능한 한글 IME의 근본 제약.

**NixOS/SSH**: `vim.fn.executable("macism") == 1`로 자동 비활성화. 성능 영향 없음.

## 플러그인 업데이트

```vim
:Lazy update           " 모든 플러그인 최신 버전으로 업데이트
:Lazy restore          " lazy-lock.json 기준으로 복원
```

업데이트 후 `lazy-lock.json` 변경사항을 커밋하여 호스트 간 동기화.

## Nix 빌드 실패 (extraPackages)

```bash
# 패키지명 확인
nix search nixpkgs#vtsls
nix search nixpkgs#tailwindcss-language-server

# 빌드 테스트
nix build nixpkgs#vtsls
```

## ESLint 진단 중복

**원인**: eslint extra + nvim-lint에서 eslint_d를 별도 설정.
**해결**: LazyVim eslint extra만 사용. `eslint_d` 별도 설정 제거.

## macOS에서 nrs 빌드가 수십 분 멈춤 (LLVM 소스 빌드)

```
[1/13/58 built, 203 copied ...] building
# ps aux로 확인하면 clang++이 llvm-project를 컴파일 중
```

**원인**: `extraPackages`에 `gcc`를 무조건 추가하면, macOS에서 GCC의 의존성인 **LLVM 전체를 소스에서 빌드**한다. nixpkgs 바이너리 캐시에 macOS용 GCC가 없기 때문.

**해결**: `gcc`를 Linux 전용으로 변경. macOS는 clang이 이미 있어 tree-sitter 파서 컴파일이 가능하다.

```nix
extraPackages = with pkgs; [ ... ]
++ lib.optionals pkgs.stdenv.isLinux [
  gcc  # NixOS 전용
];
```

**예방**: extraPackages에 C/C++ 컴파일러나 대형 빌드 도구를 추가할 때는 반드시 플랫폼 조건을 확인할 것. `pkgs.stdenv.isLinux` / `pkgs.stdenv.isDarwin`으로 분기.

## marksman이 Swift 소스 빌드를 트리거 (빌드 실패)

```
error: Cannot build swift-5.10.1.drv
  → swift-wrapper-5.10.1 → dotnet-vmr-9.0.12 → dotnet-runtime → marksman
```

**원인**: `marksman`(Markdown LSP)은 .NET 앱. macOS에서 dotnet-runtime이 Swift를 빌드 의존성으로 요구하는데, nixpkgs 바이너리 캐시에 없어 소스 빌드 → clang 호환성 문제로 실패.

**해결**: `marksman` → `markdown-oxide`(Rust)로 교체. dotnet/Swift 의존성 없이 동일 기능 제공.

```nix
# default.nix
markdown-oxide  # marksman 대신 사용

# lsp.lua
markdown_oxide = {},
marksman = { enabled = false },
```

**교훈**: extraPackages 추가 시 `nix path-info -r nixpkgs#패키지명 | grep -ci swift` 등으로 무거운 의존성 체인이 없는지 사전 확인할 것.

## indent-blankline setup 함수 호출 실패

```
Error: You are trying to call the setup function of indent-blankline...
Take a look at the GitHub wiki for instructions on how to migrate.
```

**원인**: indent-blankline v3에서 모듈 이름이 `indent_blankline` → `ibl`로 변경됨. lazy.nvim이 플러그인명에서 모듈명을 추론하면 `indent-blankline`을 호출 → v2 호환 에러 발생.

**해결**: ui.lua의 플러그인 spec에 `main = "ibl"` 명시.

```lua
{
  "lukas-reineke/indent-blankline.nvim",
  main = "ibl",  -- v3 필수: 모듈명 명시
  opts = { ... },
}
```

**참고**: LazyVim 코어가 `main = "ibl"`을 설정하더라도, 커스텀 spec에서 명시적으로 지정하는 것이 안전함.

## tree-sitter CLI 누락 (파서 컴파일 불가)

```
Unmet requirements for nvim-treesitter main:
- ✅ C compiler
- ✅ curl
- ✅ tar
- ❌ tree-sitter (CLI)
```

**원인**: nvim-treesitter main 브랜치가 `tree-sitter` CLI를 필수 의존성으로 요구. `extraPackages`에 미포함 시 파서 설치 시 무한 행이 발생하거나 컴파일 실패.

**해결**: `default.nix`의 `extraPackages`에 `tree-sitter` 추가.

```nix
extraPackages = with pkgs; [
  tree-sitter  # nvim-treesitter 파서 컴파일 CLI
  # ...
];
```

**참고**: nixpkgs의 tree-sitter 버전이 nvim-treesitter 요구 버전(>= 0.26.1)보다 낮을 수 있음. `:checkhealth nvim-treesitter`로 버전 호환성 확인 필요.

## mini.surround 조직 이름 변경 경고

```
Plugin echasnovski/mini.surround was renamed to nvim-mini/mini.surround
Please update your config for LazyVim
```

**원인**: mini.nvim 0.17.0 (2025-12)에서 `echasnovski` 개인 계정 → `nvim-mini` 조직으로 이전. lazy.nvim은 `owner/repo` 문자열로 매칭하므로 옛 이름이면 경고 발생.

**해결**: `disabled.lua`에서 조직명 변경.

```lua
-- 올바른 방법
{ "nvim-mini/mini.surround", enabled = false }

-- 잘못된 방법 (경고 발생)
{ "echasnovski/mini.surround", enabled = false }
```

**교훈**: LazyVim 업데이트 후 플러그인 조직 이전 경고가 나타나면 `disabled.lua`의 `owner/repo`를 확인할 것.

## which-key 사용법

**증상**: 키를 뭘 눌러야 할지 모르겠다.

**해결**: Normal 모드에서 **Space**를 누르고 기다리면 which-key 팝업이 뜬다. 카테고리별로 가능한 키가 전부 나열된다.

## 파일 저장

`:w` 입력 후 Enter. LazyVim은 Insert 모드를 벗어나면 자동 저장하므로, 보통은 직접 저장할 필요 없다.

## 터미널 true color

**증상**: 터미널 색상이 이상하다.

**원인**: 터미널이 true color를 미지원.

**해결**: Ghostty, iTerm2, Kitty 등 사용. Termius는 제한적.

```bash
# true color 테스트
echo -e "\033[38;2;255;100;0mTRUECOLOR\033[0m"
```

## 자동 포맷 미동작

**증상**: 저장 시 자동 포맷이 안 된다.

**진단**:
1. `<leader>cf`로 수동 포맷 테스트
2. 동작하면 autoformat 설정 문제, 안 되면 포매터 바이너리 문제

```vim
:LazyFormatInfo      " 현재 파일의 포매터 설정 확인
```

## jk 매핑 딜레이

**증상**: Insert 모드에서 "j"를 누르면 잠깐 멈춘다.

**원인**: `jk` → Esc 매핑 때문. "j" 입력 후 "k"를 기다리는 시간(기본 300ms) 동안 멈춤이 발생한다.

**해결**: "jk"를 사용하지 않으려면 `keymaps.lua`에서 해당 줄을 삭제하면 된다.

## 숨김 파일 표시

**증상**: 파일 탐색기에서 숨김 파일이 안 보인다.

**해결**: 기본 설정에서 dotfile과 gitignored 파일을 표시한다. 안 보인다면 탐색기에서 `H`를 눌러 숨김 파일 토글을 확인.

## 버퍼 탐색 불가

**증상**: 모든 버퍼를 닫았더니 H/L이 안 된다.

**해결**: 버퍼가 없으면 H/L 전환이 불가능하다. `<leader>ff`로 파일을 찾거나, `<leader>e`로 탐색기를 열거나, `<leader>qs`로 이전 세션을 복원하면 된다.

## 첫 실행 시 에러

**증상**: nvim을 처음 열면 에러가 뜬다.

**원인**: 첫 실행 시 lazy.nvim이 플러그인을 다운로드하고 tree-sitter 파서를 컴파일한다. 네트워크가 필요하며, 완료까지 잠깐 기다려야 한다.

**해결**: 에러가 지속되면 클린 재설치:

```bash
rm -rf ~/.local/share/nvim ~/.local/state/nvim ~/.cache/nvim
nvim
```

## 설정 파일 위치

`~/.config/nvim`이 이 repo의 `modules/shared/programs/neovim/files/nvim/`으로 심볼릭 링크되어 있다. 해당 디렉토리의 Lua 파일을 직접 수정하면 nvim 재시작 시 반영된다. `nrs` 빌드가 필요 없다.
